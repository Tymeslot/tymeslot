defmodule Tymeslot.Meetings.ParticipantQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :meetings
  @moduletag :queries

  import Tymeslot.Factory

  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.ParticipantSchema

  describe "insert/1" do
    test "inserts a participant with a generated management token" do
      meeting = insert(:meeting)

      assert {:ok, %ParticipantSchema{} = participant} =
               ParticipantQueries.insert(%{
                 meeting_id: meeting.id,
                 name: "Ada Lovelace",
                 email: "ada@example.com",
                 timezone: "Europe/London"
               })

      assert participant.meeting_id == meeting.id
      assert byte_size(participant.management_token) > 0
    end

    test "returns a changeset error for missing required fields" do
      assert {:error, %Ecto.Changeset{} = changeset} = ParticipantQueries.insert(%{})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "get_by_token/1" do
    test "finds a participant by management token" do
      participant = insert(:participant)
      participant_id = participant.id

      assert {:ok, %ParticipantSchema{id: ^participant_id}} =
               ParticipantQueries.get_by_token(participant.management_token)
    end

    test "returns not_found for an unknown token" do
      assert {:error, :not_found} = ParticipantQueries.get_by_token("unknown-token")
    end
  end

  describe "list_live_for_meeting/1" do
    test "lists only live participants, oldest first" do
      meeting = insert(:meeting)
      now = DateTime.utc_now(:second)

      first =
        insert(:participant, meeting: meeting, inserted_at: DateTime.add(now, -120, :second))

      second =
        insert(:participant, meeting: meeting, inserted_at: DateTime.add(now, -60, :second))

      _cancelled = insert(:participant, meeting: meeting, cancelled_at: now)

      first_id = first.id
      second_id = second.id

      assert [%ParticipantSchema{id: ^first_id}, %ParticipantSchema{id: ^second_id}] =
               ParticipantQueries.list_live_for_meeting(meeting.id)
    end
  end

  describe "cancel/1" do
    test "stamps cancelled_at so the participant is no longer live" do
      participant = insert(:participant)

      assert {:ok, %ParticipantSchema{cancelled_at: %DateTime{}} = cancelled} =
               ParticipantQueries.cancel(participant)

      refute ParticipantSchema.live?(cancelled)
    end

    test "accepts an explicit cancellation time" do
      participant = insert(:participant)
      cancelled_at = DateTime.add(DateTime.utc_now(:second), -3600, :second)

      assert {:ok, %ParticipantSchema{cancelled_at: ^cancelled_at}} =
               ParticipantQueries.cancel(participant, cancelled_at)
    end
  end

  describe "count_seats_taken/1" do
    test "counts live participants plus their guests" do
      meeting = insert(:meeting)
      with_guest = insert(:participant, meeting: meeting)
      _alone = insert(:participant, meeting: meeting)

      {:ok, _guest} =
        GuestQueries.insert_guest(%{
          meeting_id: meeting.id,
          email: "plus-one@example.com",
          participant_id: with_guest.id
        })

      assert ParticipantQueries.count_seats_taken(meeting.id) == 3
    end

    test "ignores cancelled participants and their guests" do
      meeting = insert(:meeting)
      _live = insert(:participant, meeting: meeting)

      cancelled =
        insert(:participant, meeting: meeting, cancelled_at: DateTime.utc_now(:second))

      {:ok, _guest} =
        GuestQueries.insert_guest(%{
          meeting_id: meeting.id,
          email: "ghost@example.com",
          participant_id: cancelled.id
        })

      assert ParticipantQueries.count_seats_taken(meeting.id) == 1
    end

    test "returns zero for a meeting without participants" do
      meeting = insert(:meeting)
      assert ParticipantQueries.count_seats_taken(meeting.id) == 0
    end
  end

  describe "seat_counts_for_range/3" do
    test "groups seats by meeting start time for one meeting type" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user)

      slot_one = DateTime.add(DateTime.utc_now(:second), 1, :day)
      slot_two = DateTime.add(slot_one, 2, :hour)

      meeting_one =
        insert(:meeting,
          organizer_user: user,
          meeting_type_id: meeting_type.id,
          start_time: slot_one,
          end_time: DateTime.add(slot_one, 30, :minute)
        )

      meeting_two =
        insert(:meeting,
          organizer_user: user,
          meeting_type_id: meeting_type.id,
          start_time: slot_two,
          end_time: DateTime.add(slot_two, 30, :minute)
        )

      with_guest = insert(:participant, meeting: meeting_one)
      _second = insert(:participant, meeting: meeting_one)
      _third = insert(:participant, meeting: meeting_two)

      {:ok, _guest} =
        GuestQueries.insert_guest(%{
          meeting_id: meeting_one.id,
          email: "plus-one@example.com",
          participant_id: with_guest.id
        })

      counts =
        ParticipantQueries.seat_counts_for_range(
          meeting_type.id,
          DateTime.add(slot_one, -1, :hour),
          DateTime.add(slot_two, 1, :hour)
        )

      assert %{^slot_one => 3, ^slot_two => 1} = counts
      assert map_size(counts) == 2
    end

    test "excludes meetings of other meeting types" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user)
      other_type = insert(:meeting_type, user: user)

      start_time = DateTime.add(DateTime.utc_now(:second), 1, :day)

      meeting =
        insert(:meeting,
          organizer_user: user,
          meeting_type_id: other_type.id,
          start_time: start_time,
          end_time: DateTime.add(start_time, 30, :minute)
        )

      insert(:participant, meeting: meeting)

      assert ParticipantQueries.seat_counts_for_range(
               meeting_type.id,
               DateTime.add(start_time, -1, :hour),
               DateTime.add(start_time, 1, :hour)
             ) == %{}
    end

    test "excludes meetings that are not confirmed" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user)
      start_time = DateTime.add(DateTime.utc_now(:second), 1, :day)

      meeting =
        insert(:meeting,
          organizer_user: user,
          meeting_type_id: meeting_type.id,
          status: "cancelled",
          start_time: start_time,
          end_time: DateTime.add(start_time, 30, :minute)
        )

      insert(:participant, meeting: meeting)

      assert ParticipantQueries.seat_counts_for_range(
               meeting_type.id,
               DateTime.add(start_time, -1, :hour),
               DateTime.add(start_time, 1, :hour)
             ) == %{}
    end

    test "excludes meetings outside the range" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user)
      start_time = DateTime.add(DateTime.utc_now(:second), 10, :day)

      meeting =
        insert(:meeting,
          organizer_user: user,
          meeting_type_id: meeting_type.id,
          start_time: start_time,
          end_time: DateTime.add(start_time, 30, :minute)
        )

      insert(:participant, meeting: meeting)

      assert ParticipantQueries.seat_counts_for_range(
               meeting_type.id,
               DateTime.add(start_time, -3, :day),
               DateTime.add(start_time, -1, :day)
             ) == %{}
    end
  end
end
