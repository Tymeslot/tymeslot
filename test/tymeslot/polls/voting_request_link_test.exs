defmodule Tymeslot.Polls.VotingRequestLinkTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :unit
  @moduletag :polls

  import Tymeslot.Factory

  alias Tymeslot.Polls
  alias Tymeslot.Polls.{PollParticipantQueries, PollSchema, Voting}
  alias Tymeslot.Workers.EmailWorker

  describe "request_link/2" do
    test "creates an unconfirmed participant and emails them their link" do
      poll = insert(:poll)

      assert {:ok, :sent} =
               Voting.request_link(poll, %{name: "Alice", email: "Alice@Example.com "})

      participant = PollParticipantQueries.get_by_poll_and_email(poll.id, "alice@example.com")
      assert participant.name == "Alice"
      assert is_binary(participant.token) and participant.token != ""
      assert participant.confirmed_at == nil
      assert %DateTime{} = participant.link_sent_at

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_poll_participant_link", "participant_id" => participant.id}
      )

      assert PollParticipantQueries.count_confirmed(poll.id) == 0
      assert PollParticipantQueries.count_unconfirmed(poll.id) == 1
    end

    test "an unconfirmed participant counts nowhere on the poll" do
      poll = insert(:poll)
      {:ok, :sent} = Voting.request_link(poll, %{name: "Alice", email: "alice@example.com"})

      {:ok, loaded} = Polls.get_poll_for_voting(poll.token)
      assert loaded.participants == []
    end

    test "a confirmed address is told it is on the poll, gets its link again and keeps its details" do
      poll = insert(:poll)

      first =
        insert(:poll_participant,
          poll: poll,
          name: "Alice",
          email: "alice@example.com",
          timezone: "Etc/UTC"
        )

      assert {:ok, :resent} =
               Voting.request_link(poll, %{
                 name: "Mallory",
                 email: " ALICE@example.com ",
                 timezone: "Europe/Berlin"
               })

      again = PollParticipantQueries.get_by_poll_and_email(poll.id, "alice@example.com")
      assert again.id == first.id
      assert again.name == "Alice"
      assert again.timezone == "Etc/UTC"
      assert again.token == first.token
      assert PollParticipantQueries.count_confirmed(poll.id) == 1
      assert PollParticipantQueries.count_unconfirmed(poll.id) == 0

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_poll_participant_link", "participant_id" => first.id}
      )
    end

    test "sends a link at most once per address within the resend window, and says so" do
      poll = insert(:poll)
      attrs = %{name: "Alice", email: "alice@example.com"}

      assert {:ok, :sent} = Voting.request_link(poll, attrs)
      assert {:ok, :throttled} = Voting.request_link(poll, attrs)
      assert {:ok, :throttled} = Voting.request_link(poll, attrs)

      assert length(link_jobs()) == 1
    end

    test "a known address is checked like a new one: an invalid name sends and changes nothing" do
      poll = insert(:poll)

      insert(:poll_participant,
        poll: poll,
        name: "Alice",
        email: "alice@example.com",
        confirmed_at: nil,
        link_sent_at: DateTime.add(now(), -11, :minute)
      )

      for name <- [nil, "  ", "A", "<script>"] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Voting.request_link(poll, %{name: name, email: "alice@example.com"})

        assert Keyword.has_key?(changeset.errors, :name)
      end

      assert link_jobs() == []

      assert PollParticipantQueries.get_by_poll_and_email(poll.id, "alice@example.com").name ==
               "Alice"
    end

    test "a request for an unconfirmed address replaces its name, timezone and locale" do
      poll = insert(:poll)

      pending =
        insert(:poll_participant,
          poll: poll,
          name: "Mallory",
          email: "alice@example.com",
          timezone: "Etc/UTC",
          locale: "en",
          confirmed_at: nil,
          link_sent_at: now()
        )

      assert {:ok, :throttled} =
               Voting.request_link(poll, %{
                 name: " Alice ",
                 email: "alice@example.com",
                 timezone: "Europe/Berlin",
                 locale: "de"
               })

      reloaded = PollParticipantQueries.get_by_poll_and_email(poll.id, "alice@example.com")
      assert reloaded.id == pending.id
      assert reloaded.token == pending.token
      assert reloaded.name == "Alice"
      assert reloaded.timezone == "Europe/Berlin"
      assert reloaded.locale == "de"
    end

    test "a request for an unconfirmed address can set the locale back to English" do
      poll = insert(:poll)

      insert(:poll_participant,
        poll: poll,
        email: "alice@example.com",
        locale: "de",
        confirmed_at: nil,
        link_sent_at: now()
      )

      assert {:ok, :throttled} =
               Voting.request_link(poll, %{
                 name: "Alice",
                 email: "alice@example.com",
                 locale: "en"
               })

      assert PollParticipantQueries.get_by_poll_and_email(poll.id, "alice@example.com").locale ==
               "en"
    end

    test "an unknown timezone or locale in a request leaves the stored ones alone" do
      poll = insert(:poll)

      insert(:poll_participant,
        poll: poll,
        name: "Mallory",
        email: "alice@example.com",
        timezone: "Etc/UTC",
        locale: "en",
        confirmed_at: nil,
        link_sent_at: now()
      )

      assert {:ok, :throttled} =
               Voting.request_link(poll, %{
                 name: "Alice",
                 email: "alice@example.com",
                 timezone: "Mars/Olympus_Mons",
                 locale: "xx"
               })

      reloaded = PollParticipantQueries.get_by_poll_and_email(poll.id, "alice@example.com")
      assert reloaded.name == "Alice"
      assert reloaded.timezone == "Etc/UTC"
      assert reloaded.locale == "en"
    end

    test "sends the link again once the resend window has passed" do
      poll = insert(:poll)

      participant =
        insert(:poll_participant,
          poll: poll,
          email: "alice@example.com",
          link_sent_at: DateTime.add(DateTime.utc_now(), -11, :minute)
        )

      assert {:ok, :resent} =
               Voting.request_link(poll, %{name: "Alice", email: "alice@example.com"})

      assert [%{args: %{"participant_id" => id}}] = link_jobs()
      assert id == participant.id
    end

    test "a request for an expired unconfirmed address starts over with a new link" do
      poll = insert(:poll)

      expired =
        insert(:poll_participant,
          poll: poll,
          name: "Old",
          email: "alice@example.com",
          confirmed_at: nil,
          inserted_at: DateTime.add(now(), -49, :hour),
          link_sent_at: DateTime.add(now(), -1, :hour)
        )

      assert {:ok, :sent} =
               Voting.request_link(poll, %{name: "Alice", email: "alice@example.com"})

      assert Voting.get_participant(poll, expired.token) == nil

      fresh = PollParticipantQueries.get_by_poll_and_email(poll.id, "alice@example.com")
      assert fresh.id != expired.id
      assert fresh.name == "Alice"
      assert Voting.get_participant(poll, fresh.token).id == fresh.id

      assert [%{args: %{"participant_id" => id}}] = link_jobs()
      assert id == fresh.id
    end

    test "an expired request starting over is refused when live requests fill the cap" do
      poll = insert(:poll)

      expired =
        insert(:poll_participant,
          poll: poll,
          email: "alice@example.com",
          confirmed_at: nil,
          inserted_at: DateTime.add(now(), -49, :hour),
          link_sent_at: DateTime.add(now(), -49, :hour)
        )

      insert_list(PollSchema.max_unconfirmed_participants(), :poll_participant,
        poll: poll,
        confirmed_at: nil
      )

      assert {:error, :too_many_requests} =
               Voting.request_link(poll, %{name: "Alice", email: "alice@example.com"})

      assert PollParticipantQueries.get_by_poll_and_email(poll.id, "alice@example.com") == nil
      assert Voting.get_participant(poll, expired.token) == nil

      assert PollParticipantQueries.count_unconfirmed(poll.id) ==
               PollSchema.max_unconfirmed_participants()

      assert link_jobs() == []
    end

    test "a link sent again recently still expires 48 hours after the first request" do
      poll = insert(:poll)

      pending =
        insert(:poll_participant,
          poll: poll,
          confirmed_at: nil,
          inserted_at: DateTime.add(now(), -49, :hour),
          link_sent_at: now()
        )

      assert Voting.get_participant(poll, pending.token) == nil
      assert PollParticipantQueries.count_unconfirmed(poll.id) == 0
      assert {1, nil} = Polls.prune_unconfirmed_participants()
    end

    test "requests resent over and over cannot hold the request cap past 48 hours" do
      poll = insert(:poll)

      insert_list(PollSchema.max_unconfirmed_participants(), :poll_participant,
        poll: poll,
        confirmed_at: nil,
        inserted_at: DateTime.add(now(), -49, :hour),
        link_sent_at: now()
      )

      assert {:ok, :sent} = Voting.request_link(poll, %{name: "Real", email: "real@example.com"})
    end

    test "returns {:error, :voting_closed} when the poll is not open" do
      poll = insert(:poll, status: :cancelled)

      assert {:error, :voting_closed} =
               Voting.request_link(poll, %{name: "Alice", email: "alice@example.com"})
    end

    test "returns the changeset for an invalid address and sends nothing" do
      poll = insert(:poll)

      assert {:error, %Ecto.Changeset{}} =
               Voting.request_link(poll, %{name: "Alice", email: "not-an-address"})

      assert {:error, %Ecto.Changeset{}} = Voting.request_link(poll, %{name: "Alice"})
      assert link_jobs() == []
    end

    test "returns {:error, :poll_full} for a new address once the confirmed cap is reached" do
      poll = insert(:poll)
      insert_list(PollSchema.max_participants(), :poll_participant, poll: poll)

      assert {:error, :poll_full} =
               Voting.request_link(poll, %{name: "Late", email: "late@example.com"})
    end

    test "unconfirmed requests do not fill the poll" do
      poll = insert(:poll)
      insert_list(PollSchema.max_participants() - 1, :poll_participant, poll: poll)
      insert_list(5, :poll_participant, poll: poll, confirmed_at: nil, link_sent_at: now())

      assert {:ok, :sent} = Voting.request_link(poll, %{name: "Real", email: "real@example.com"})
    end

    test "returns {:error, :too_many_requests} once too many links are out unconfirmed" do
      poll = insert(:poll)

      insert_list(PollSchema.max_unconfirmed_participants(), :poll_participant,
        poll: poll,
        confirmed_at: nil,
        link_sent_at: now()
      )

      assert {:error, :too_many_requests} =
               Voting.request_link(poll, %{name: "Late", email: "late@example.com"})
    end

    test "expired unconfirmed requests do not count against that limit" do
      poll = insert(:poll)

      insert_list(PollSchema.max_unconfirmed_participants(), :poll_participant,
        poll: poll,
        confirmed_at: nil,
        inserted_at: DateTime.add(now(), -3, :day),
        link_sent_at: DateTime.add(now(), -3, :day)
      )

      assert {:ok, :sent} = Voting.request_link(poll, %{name: "Real", email: "real@example.com"})
    end
  end

  defp now, do: DateTime.utc_now(:second)

  defp link_jobs do
    Enum.filter(
      all_enqueued(worker: EmailWorker),
      &(&1.args["action"] == "send_poll_participant_link")
    )
  end
end
