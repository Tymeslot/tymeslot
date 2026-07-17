defmodule Tymeslot.Polls.PollQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.Polls.{PollParticipantQueries, PollQueries, PollVoteQueries}

  describe "get_by_token/1" do
    test "returns preloaded poll for a known token, nil otherwise" do
      poll = insert(:poll)
      slot = insert(:poll_time_slot, poll: poll)
      participant = insert(:poll_participant, poll: poll)

      loaded = PollQueries.get_by_token(poll.token)

      assert loaded.id == poll.id
      assert [%{id: slot_id}] = loaded.time_slots
      assert slot_id == slot.id
      assert [%{id: participant_id, votes: []}] = loaded.participants
      assert participant_id == participant.id

      assert PollQueries.get_by_token("nope") == nil
    end
  end

  describe "get_for_user/2" do
    test "scopes to the owner" do
      poll = insert(:poll)
      other_user = insert(:user)

      assert %{id: id} = PollQueries.get_for_user(poll.id, poll.user_id)
      assert id == poll.id
      assert PollQueries.get_for_user(poll.id, other_user.id) == nil
    end
  end

  describe "upsert_votes/1" do
    test "inserts then replaces on conflict" do
      poll = insert(:poll)
      slot = insert(:poll_time_slot, poll: poll)
      participant = insert(:poll_participant, poll: poll)

      assert {1, _rows} =
               PollVoteQueries.upsert_votes([
                 %{
                   poll_participant_id: participant.id,
                   poll_time_slot_id: slot.id,
                   response: :yes
                 }
               ])

      assert {1, _rows} =
               PollVoteQueries.upsert_votes([
                 %{poll_participant_id: participant.id, poll_time_slot_id: slot.id, response: :no}
               ])

      assert [%{response: :no}] = PollVoteQueries.list_for_participant(participant.id)
    end
  end

  describe "get_by_poll_and_email/2" do
    test "finds registered participant" do
      participant = insert(:poll_participant, email: "ada@example.com")

      assert %{id: id} =
               PollParticipantQueries.get_by_poll_and_email(
                 participant.poll_id,
                 "ada@example.com"
               )

      assert id == participant.id

      assert PollParticipantQueries.get_by_poll_and_email(participant.poll_id, "x@example.com") ==
               nil
    end
  end
end
