defmodule Tymeslot.Polls.EmailLimitsTest do
  @moduledoc """
  The poll email limits: the addresses a host invites, the emails one address
  is sent, and the voting-link requests one poll takes.
  """

  # async: false: these tests fill shared rate-limit buckets, which another
  # module's setup would otherwise clear mid-test.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :polls
  @moduletag :integration

  alias Ecto.UUID
  alias Tymeslot.Polls
  alias Tymeslot.Polls.{EmailLimits, Invitations, PollParticipantQueries, PollSchema, Voting}
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.EmailWorker

  defp address(name), do: "#{name}-#{System.unique_integer([:positive])}@example.com"
  defp host_id, do: System.unique_integer([:positive])

  defp fill(name, key),
    do: :ok = RateLimiter.consume(name, key, RateLimiter.remaining(name, key))

  defp leave(name, key, room),
    do: :ok = RateLimiter.consume(name, key, RateLimiter.remaining(name, key) - room)

  describe "reserve_invitations/2" do
    test "charges the host once per address, and each address once" do
      host = host_id()
      [ada, grace] = [address("ada"), address("grace")]
      host_before = RateLimiter.remaining(:poll_host_invitations, host)
      ada_before = RateLimiter.remaining(:poll_recipient_email, ada)

      assert EmailLimits.reserve_invitations(host, [ada, grace]) ==
               {:ok, %{allowed: [ada, grace], limited: []}}

      assert RateLimiter.remaining(:poll_host_invitations, host) == host_before - 2
      assert RateLimiter.remaining(:poll_recipient_email, ada) == ada_before - 1
    end

    test "refuses a list past the host's allowance whole, and charges nothing" do
      host = host_id()
      ada = address("ada")
      leave(:poll_host_invitations, host, 1)
      ada_before = RateLimiter.remaining(:poll_recipient_email, ada)

      assert EmailLimits.reserve_invitations(host, [ada, address("grace")]) ==
               {:error, {:rate_limited, 1}}

      assert RateLimiter.remaining(:poll_host_invitations, host) == 1
      assert RateLimiter.remaining(:poll_recipient_email, ada) == ada_before
    end

    test "takes a list that uses up the allowance exactly, and nothing after it" do
      host = host_id()
      leave(:poll_host_invitations, host, 2)

      assert {:ok, %{limited: []}} =
               EmailLimits.reserve_invitations(host, [address("ada"), address("grace")])

      assert EmailLimits.reserve_invitations(host, [address("hedy")]) ==
               {:error, {:rate_limited, 0}}
    end

    test "leaves out an address over its own limit, without charging the host for it" do
      host = host_id()
      [ada, grace] = [address("ada"), address("grace")]
      fill(:poll_recipient_email, ada)
      host_before = RateLimiter.remaining(:poll_host_invitations, host)

      assert EmailLimits.reserve_invitations(host, [ada, grace]) ==
               {:ok, %{allowed: [grace], limited: [ada]}}

      assert RateLimiter.remaining(:poll_host_invitations, host) == host_before - 1
    end

    test "an empty list charges nothing" do
      host = host_id()
      before = RateLimiter.remaining(:poll_host_invitations, host)

      assert EmailLimits.reserve_invitations(host, []) == {:ok, %{allowed: [], limited: []}}
      assert RateLimiter.remaining(:poll_host_invitations, host) == before
    end
  end

  describe "invitations" do
    setup do
      user = insert(:user)
      %{user: user, poll: insert(:poll, user: user)}
    end

    defp invitation_jobs,
      do: all_enqueued(worker: EmailWorker, args: %{"action" => "send_poll_invitation"})

    test "a list past the host's allowance invites nobody", %{user: user, poll: poll} do
      leave(:poll_host_invitations, user.id, 1)
      [ada, grace] = [address("ada"), address("grace")]

      assert Invitations.invite(poll, [%{email: ada, name: nil}, %{email: grace, name: nil}]) ==
               {:error, {:rate_limited, 1}}

      assert PollParticipantQueries.get_by_poll_and_email(poll.id, ada) == nil
      assert invitation_jobs() == []
    end

    test "a list that fits the allowance exactly goes out", %{user: user, poll: poll} do
      leave(:poll_host_invitations, user.id, 2)
      entries = [%{email: address("ada"), name: nil}, %{email: address("grace"), name: nil}]

      assert {:ok, %{invited: [_ada, _grace], rate_limited: []}} =
               Invitations.invite(poll, entries)

      assert length(invitation_jobs()) == 2
    end

    test "a new poll whose invitees are past the allowance is not created", %{
      user: user,
      poll: poll
    } do
      fill(:poll_host_invitations, user.id)
      start_time = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

      attrs = %{
        title: "Team sync",
        duration_minutes: 30,
        timezone: "Etc/UTC",
        slots: [%{start_time: start_time}],
        invitees: [%{email: address("ada"), name: nil}]
      }

      assert Polls.create_poll(user.id, attrs) == {:error, {:rate_limited, 0}}
      assert Enum.map(Polls.list_polls(user.id), & &1.title) == [poll.title]
      assert invitation_jobs() == []
    end

    test "an address over its own limit is skipped and reported, the rest invited", %{
      poll: poll
    } do
      [ada, grace] = [address("ada"), address("grace")]
      fill(:poll_recipient_email, grace)

      assert {:ok, %{invited: [invited], skipped: [], rate_limited: [^grace]}} =
               Invitations.invite(poll, [%{email: grace, name: nil}, %{email: ada, name: nil}])

      assert invited.email == ada
      assert PollParticipantQueries.get_by_poll_and_email(poll.id, grace) == nil

      assert [%{args: %{"participant_id" => id}}] = invitation_jobs()
      assert id == invited.id
    end

    test "a link requester over the limit stays unconfirmed", %{poll: poll} do
      grace = address("grace")
      assert {:ok, :sent} = Voting.request_link(poll, %{name: "Grace", email: grace})
      fill(:poll_recipient_email, grace)

      assert {:ok, %{invited: [], rate_limited: [^grace]}} =
               Invitations.invite(poll, [%{email: grace, name: nil}])

      assert PollParticipantQueries.get_by_poll_and_email(poll.id, grace).confirmed_at == nil
    end

    test "someone already on the poll costs the host nothing", %{user: user, poll: poll} do
      ada = address("ada")
      insert(:poll_participant, poll: poll, email: ada)
      before = RateLimiter.remaining(:poll_host_invitations, user.id)

      assert {:ok, %{invited: [], skipped: [^ada]}} =
               Invitations.invite(poll, [%{email: ada, name: nil}])

      assert RateLimiter.remaining(:poll_host_invitations, user.id) == before
    end

    test "uninvited/2 names the new poll's invitees that were left out", %{user: user} do
      [ada, grace] = [address("ada"), address("grace")]
      fill(:poll_recipient_email, grace)
      start_time = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)
      invitees = [%{email: ada, name: nil}, %{email: grace, name: nil}]

      {:ok, poll} =
        Polls.create_poll(user.id, %{
          title: "Team sync",
          duration_minutes: 30,
          timezone: "Etc/UTC",
          slots: [%{start_time: start_time}],
          invitees: invitees
        })

      assert Enum.map(poll.participants, & &1.email) == [ada]
      assert Invitations.uninvited(poll, invitees) == [grace]
    end
  end

  describe "charge_recipient/1" do
    test "counts an address however it was typed" do
      ada = address("ada")
      before = RateLimiter.remaining(:poll_recipient_email, ada)

      assert EmailLimits.charge_recipient("  " <> String.upcase(ada) <> " ") == :ok
      assert RateLimiter.remaining(:poll_recipient_email, ada) == before - 1
    end

    test "refuses an address that has had its share" do
      ada = address("ada")
      fill(:poll_recipient_email, ada)

      assert EmailLimits.charge_recipient(ada) == {:error, :recipient_rate_limited}
    end
  end

  describe "charge_link_request/1" do
    test "answers :too_many_requests once the poll has taken its share" do
      poll = %PollSchema{id: UUID.generate()}
      assert EmailLimits.charge_link_request(poll) == :ok

      fill(:poll_link_request, poll.id)

      assert EmailLimits.charge_link_request(poll) == {:error, :too_many_requests}
    end
  end

  describe "link requests" do
    defp link_jobs,
      do: all_enqueued(worker: EmailWorker, args: %{"action" => "send_poll_participant_link"})

    test "a poll that has taken its share of requests turns the next away" do
      poll = insert(:poll)
      fill(:poll_link_request, poll.id)
      ada = address("ada")

      assert Voting.request_link(poll, %{name: "Ada", email: ada}) ==
               {:error, :too_many_requests}

      assert PollParticipantQueries.get_by_poll_and_email(poll.id, ada) == nil
      assert link_jobs() == []
    end

    test "a new address that has had too many poll emails is not added" do
      poll = insert(:poll)
      ada = address("ada")
      fill(:poll_recipient_email, ada)

      assert Voting.request_link(poll, %{name: "Ada", email: ada}) ==
               {:error, :recipient_rate_limited}

      assert PollParticipantQueries.get_by_poll_and_email(poll.id, ada) == nil
      assert link_jobs() == []
    end

    test "an address on the poll is not sent its link again once it has had its share" do
      poll = insert(:poll)
      ada = address("ada")

      insert(:poll_participant,
        poll: poll,
        email: ada,
        confirmed_at: nil,
        link_sent_at: DateTime.add(DateTime.utc_now(), -11, :minute)
      )

      fill(:poll_recipient_email, ada)

      assert Voting.request_link(poll, %{name: "Ada", email: ada}) ==
               {:error, :recipient_rate_limited}

      assert link_jobs() == []
    end

    test "a repeat inside the resend window sends nothing and costs nothing" do
      poll = insert(:poll)
      ada = address("ada")
      assert {:ok, :sent} = Voting.request_link(poll, %{name: "Ada", email: ada})
      after_first = RateLimiter.remaining(:poll_recipient_email, ada)

      assert {:ok, :throttled} = Voting.request_link(poll, %{name: "Ada", email: ada})
      assert RateLimiter.remaining(:poll_recipient_email, ada) == after_first
      assert length(link_jobs()) == 1
    end

    test "invitations and voting links draw on one budget per address" do
      ada = address("ada")
      before = RateLimiter.remaining(:poll_recipient_email, ada)

      {:ok, _result} = Invitations.invite(insert(:poll), [%{email: ada, name: nil}])
      assert {:ok, :sent} = Voting.request_link(insert(:poll), %{name: "Ada", email: ada})

      assert RateLimiter.remaining(:poll_recipient_email, ada) == before - 2
    end

    test "an invalid address is refused without charging anyone's budget" do
      poll = insert(:poll)
      before = RateLimiter.remaining(:poll_recipient_email, "not-an-address")

      assert {:error, %Ecto.Changeset{}} =
               Voting.request_link(poll, %{name: "Ada", email: "not-an-address"})

      assert RateLimiter.remaining(:poll_recipient_email, "not-an-address") == before
    end
  end
end
