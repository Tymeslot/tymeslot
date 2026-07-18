defmodule Tymeslot.Polls.VotingTest do
  use Tymeslot.DataCase, async: true

  @moduletag :unit

  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Polls
  alias Tymeslot.Polls.{PollParticipantQueries, PollVoteQueries, Voting}

  describe "register_participant/2" do
    test "creates a participant with a generated token" do
      poll = insert(:poll)

      assert {:ok, participant} =
               Voting.register_participant(poll, %{name: "Alice", email: "Alice@Example.com "})

      assert participant.poll_id == poll.id
      assert participant.name == "Alice"
      assert participant.email == "alice@example.com"
      assert is_binary(participant.token) and participant.token != ""
      assert PollParticipantQueries.count_for_poll(poll.id) == 1
    end

    test "resumes an existing registration for the same email without duplicating" do
      poll = insert(:poll)

      assert {:ok, first} =
               Voting.register_participant(poll, %{name: "Alice", email: "alice@example.com"})

      assert {:ok, second} =
               Voting.register_participant(poll, %{
                 name: "Alice Again",
                 email: " ALICE@example.com "
               })

      assert second.id == first.id
      assert PollParticipantQueries.count_for_poll(poll.id) == 1
    end

    test "returns {:error, :voting_closed} when the poll is not open" do
      poll = insert(:poll, status: :cancelled)

      assert {:error, :voting_closed} =
               Voting.register_participant(poll, %{name: "Alice", email: "alice@example.com"})
    end

    test "returns {:error, :poll_full} once the participant cap is reached" do
      poll = insert(:poll)
      insert_list(40, :poll_participant, poll: poll)

      assert {:error, :poll_full} =
               Voting.register_participant(poll, %{name: "Late", email: "late@example.com"})
    end
  end

  describe "cast_votes/3" do
    setup do
      poll = insert(:poll)
      start_a = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)
      start_b = DateTime.add(start_a, 2, :hour)

      slot_a =
        insert(:poll_time_slot,
          poll: poll,
          start_time: start_a,
          end_time: DateTime.add(start_a, 1, :hour)
        )

      slot_b =
        insert(:poll_time_slot,
          poll: poll,
          start_time: start_b,
          end_time: DateTime.add(start_b, 1, :hour)
        )

      participant = insert(:poll_participant, poll: poll)
      poll = %{poll | time_slots: [slot_a, slot_b]}

      %{poll: poll, slot_a: slot_a, slot_b: slot_b, participant: participant}
    end

    test "persists votes, stamps voted_at, and broadcasts", ctx do
      %{poll: poll, slot_a: slot_a, slot_b: slot_b, participant: participant} = ctx
      Polls.subscribe(poll.id)

      assert {:ok, _participant} =
               Voting.cast_votes(poll, participant.token, %{
                 slot_a.id => "yes",
                 slot_b.id => "if_need_be"
               })

      votes = PollVoteQueries.list_for_participant(participant.id)
      assert length(votes) == 2

      responses = Map.new(votes, &{&1.poll_time_slot_id, &1.response})
      assert responses[slot_a.id] == :yes
      assert responses[slot_b.id] == :if_need_be

      assert PollParticipantQueries.get_by_token(participant.token).voted_at != nil
      assert_receive {:poll_updated, poll_id}
      assert poll_id == poll.id
    end

    test "replaces an existing vote for the same slot", ctx do
      %{poll: poll, slot_a: slot_a, participant: participant} = ctx

      assert {:ok, _first} = Voting.cast_votes(poll, participant.token, %{slot_a.id => "yes"})

      assert {:ok, _replacement} =
               Voting.cast_votes(poll, participant.token, %{slot_a.id => "no"})

      assert [vote] = PollVoteQueries.list_for_participant(participant.id)
      assert vote.poll_time_slot_id == slot_a.id
      assert vote.response == :no
    end

    test "accepts atom responses and the hyphenated if-need-be form", ctx do
      %{poll: poll, slot_a: slot_a, slot_b: slot_b, participant: participant} = ctx

      assert {:ok, _result} =
               Voting.cast_votes(poll, participant.token, %{
                 slot_a.id => :yes,
                 slot_b.id => "if-need-be"
               })

      responses =
        participant.id
        |> PollVoteQueries.list_for_participant()
        |> Map.new(&{&1.poll_time_slot_id, &1.response})

      assert responses[slot_a.id] == :yes
      assert responses[slot_b.id] == :if_need_be
    end

    test "rejects an unknown slot id and writes nothing", ctx do
      %{poll: poll, participant: participant} = ctx

      assert {:error, :invalid_slot} =
               Voting.cast_votes(poll, participant.token, %{UUID.generate() => "yes"})

      assert PollVoteQueries.list_for_participant(participant.id) == []
      assert PollParticipantQueries.get_by_token(participant.token).voted_at == nil
    end

    test "rejects an invalid response", ctx do
      %{poll: poll, slot_a: slot_a, participant: participant} = ctx

      assert {:error, :invalid_response} =
               Voting.cast_votes(poll, participant.token, %{slot_a.id => "maybe"})

      assert PollVoteQueries.list_for_participant(participant.id) == []
      assert PollParticipantQueries.get_by_token(participant.token).voted_at == nil
    end

    test "rejects the whole request when one slot in a multi-slot call is invalid", ctx do
      %{poll: poll, slot_a: slot_a, slot_b: slot_b, participant: participant} = ctx

      assert {:error, :invalid_response} =
               Voting.cast_votes(poll, participant.token, %{
                 slot_a.id => "yes",
                 slot_b.id => "maybe"
               })

      assert PollVoteQueries.list_for_participant(participant.id) == []
      assert PollParticipantQueries.get_by_token(participant.token).voted_at == nil
    end

    test "rejects an unknown participant token", ctx do
      %{poll: poll} = ctx

      assert {:error, :unknown_participant} =
               Voting.cast_votes(poll, "no-such-token", %{})
    end

    test "rejects a token that belongs to a different poll", ctx do
      %{poll: poll, slot_a: slot_a} = ctx
      other_participant = insert(:poll_participant)

      assert {:error, :unknown_participant} =
               Voting.cast_votes(poll, other_participant.token, %{slot_a.id => "yes"})
    end

    test "returns {:error, :voting_closed} on a past-deadline poll", ctx do
      %{slot_a: slot_a, participant: participant} = ctx
      past = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
      closed_poll = insert(:poll, deadline_at: past)
      closed_poll = %{closed_poll | time_slots: [slot_a]}

      assert {:error, :voting_closed} =
               Voting.cast_votes(closed_poll, participant.token, %{slot_a.id => "yes"})
    end

    test "an empty votes map returns the participant without stamping voted_at", ctx do
      %{poll: poll, participant: participant} = ctx

      assert {:ok, returned} = Voting.cast_votes(poll, participant.token, %{})
      assert returned.id == participant.id
      assert PollParticipantQueries.get_by_token(participant.token).voted_at == nil
      assert PollVoteQueries.list_for_participant(participant.id) == []
    end
  end
end
