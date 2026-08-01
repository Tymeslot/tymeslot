defmodule TymeslotWeb.Themes.Core.PollVotingTest do
  use Tymeslot.DataCase, async: true

  @moduletag :unit

  alias Ecto.UUID
  alias Tymeslot.Polls
  alias Tymeslot.Polls.Voting
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Themes.Core.PollVoting

  # A minimal disconnected socket: enough for assign/put_flash, without a
  # transport pid so `assign_poll_state` does not subscribe. Event round-trips
  # that call `push_patch` are covered by Task 16's LiveView mount test.
  defp socket(assigns \\ %{}) do
    base = %{__changed__: %{}, flash: %{}, client_ip: "203.0.113.5"}

    %Phoenix.LiveView.Socket{
      transport_pid: nil,
      assigns: Map.merge(base, assigns)
    }
  end

  defp flash(socket, kind), do: socket.assigns.flash[to_string(kind)]

  describe "assign_poll_state/3" do
    test "assigns poll, tallies, and voting_open" do
      poll = insert(:poll)
      insert(:poll_time_slot, poll: poll)
      {:ok, poll} = Polls.get_poll_for_voting(poll.token)

      socket = PollVoting.assign_poll_state(socket(), poll, %{})

      assert socket.assigns.poll.id == poll.id
      assert socket.assigns.voting_open == true
      assert map_size(socket.assigns.tallies) == 1
      assert socket.assigns.participant == nil
    end

    test "resolves the ?p= token to the poll's participant" do
      poll = insert(:poll)
      participant = insert(:poll_participant, poll: poll)
      {:ok, poll} = Polls.get_poll_for_voting(poll.token)

      socket = PollVoting.assign_poll_state(socket(), poll, %{"p" => participant.token})

      assert socket.assigns.participant.id == participant.id
    end

    test "ignores a token that belongs to a different poll" do
      poll = insert(:poll)
      other_poll = insert(:poll)
      other_participant = insert(:poll_participant, poll: other_poll)
      {:ok, poll} = Polls.get_poll_for_voting(poll.token)

      socket = PollVoting.assign_poll_state(socket(), poll, %{"p" => other_participant.token})

      assert socket.assigns.participant == nil
    end

    test "ignores an unknown token" do
      poll = insert(:poll)
      {:ok, poll} = Polls.get_poll_for_voting(poll.token)

      socket = PollVoting.assign_poll_state(socket(), poll, %{"p" => "does-not-exist"})

      assert socket.assigns.participant == nil
    end
  end

  describe "handle_poll_event/3" do
    test "unknown event returns the socket unchanged" do
      socket = socket(%{poll: :sentinel})

      assert {:noreply, ^socket} = PollVoting.handle_poll_event("nope", %{}, socket)
    end

    test "cast_votes with a non-map votes payload is a no-op and does not crash" do
      poll = insert(:poll)
      participant = insert(:poll_participant, poll: poll)
      {:ok, poll} = Polls.get_poll_for_voting(poll.token)
      socket = socket(%{poll: poll, participant: participant})

      # A malicious registered visitor can push a list or nil instead of a map;
      # the guard must reject it rather than reaching Map.keys/1 and raising.
      assert {:noreply, ^socket} =
               PollVoting.handle_poll_event("cast_votes", %{"votes" => [1, 2]}, socket)

      assert {:noreply, ^socket} =
               PollVoting.handle_poll_event("cast_votes", %{"votes" => nil}, socket)
    end

    test "cast_votes without a registered participant flashes and does not crash" do
      poll = insert(:poll)
      {:ok, poll} = Polls.get_poll_for_voting(poll.token)
      socket = socket(%{poll: poll, participant: nil})

      assert {:noreply, updated} =
               PollVoting.handle_poll_event("cast_votes", %{"votes" => %{}}, socket)

      assert flash(updated, :error) =~ "register"
    end

    test "cast_votes saves responses and reloads tallies for a registered participant" do
      poll = insert(:poll)
      slot = insert(:poll_time_slot, poll: poll)
      participant = insert(:poll_participant, poll: poll)
      {:ok, poll} = Polls.get_poll_for_voting(poll.token)
      socket = socket(%{poll: poll, participant: participant})

      votes = %{slot.id => "yes"}

      assert {:noreply, updated} =
               PollVoting.handle_poll_event("cast_votes", %{"votes" => votes}, socket)

      assert flash(updated, :info) =~ "saved"
      assert updated.assigns.tallies[slot.id].yes == 1
      assert %DateTime{} = updated.assigns.participant.voted_at
    end

    test "register with a rate-limited IP flashes without registering" do
      poll = insert(:poll)
      {:ok, poll} = Polls.get_poll_for_voting(poll.token)

      # A per-test-unique client identifier so this test's register bucket cannot
      # collide with the shared RateLimiter ETS state other async tests exercise
      # (they use the default socket IP). Exhausting a private bucket keeps this
      # assertion deterministic in a combined run.
      client_ip = "ratelimit-test-#{System.unique_integer([:positive])}"
      socket = socket(%{poll: poll, participant: nil, client_ip: client_ip})

      # Exhaust the register bucket for this IP before the event fires.
      bucket = "poll_register:" <> client_ip
      for _i <- 1..6, do: RateLimiter.check_rate_limit(bucket, 5, 60_000)

      assert {:noreply, updated} =
               PollVoting.handle_poll_event(
                 "register_participant",
                 %{"name" => "Ada", "email" => "ada@example.com"},
                 socket
               )

      assert flash(updated, :error) =~ "Too many"
      assert updated.assigns.participant == nil
    end
  end

  describe "handle_poll_info/2" do
    test "reloads tallies when the update is for the assigned poll" do
      poll = insert(:poll)
      slot = insert(:poll_time_slot, poll: poll)
      participant = insert(:poll_participant, poll: poll)
      {:ok, loaded} = Polls.get_poll_for_voting(poll.token)
      socket = socket(%{poll: loaded, participant: participant})

      # Cast a vote out of band, then deliver the broadcast.
      {:ok, _vote} = Voting.cast_votes(loaded, participant.token, %{slot.id => "yes"})

      assert {:noreply, updated} =
               PollVoting.handle_poll_info({:poll_updated, poll.id}, socket)

      assert updated.assigns.tallies[slot.id].yes == 1
    end

    test "ignores an update for a different poll" do
      poll = insert(:poll)
      {:ok, loaded} = Polls.get_poll_for_voting(poll.token)
      socket = socket(%{poll: loaded})

      assert {:noreply, ^socket} =
               PollVoting.handle_poll_info({:poll_updated, UUID.generate()}, socket)
    end
  end
end
