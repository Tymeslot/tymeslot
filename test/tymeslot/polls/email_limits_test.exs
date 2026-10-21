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

  alias Tymeslot.Polls.{EmailLimits, PollSchema}
  alias Tymeslot.Security.RateLimiter

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
      poll = %PollSchema{id: Ecto.UUID.generate()}
      assert EmailLimits.charge_link_request(poll) == :ok

      fill(:poll_link_request, poll.id)

      assert EmailLimits.charge_link_request(poll) == {:error, :too_many_requests}
    end
  end
end
