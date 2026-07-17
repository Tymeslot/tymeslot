defmodule Tymeslot.Meetings.MeetingConflictQueriesTest do
  @moduledoc false

  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :meetings
  @moduletag :queries

  alias Tymeslot.Meetings.MeetingConflictQueries
  alias Tymeslot.Repo

  describe "time_conflict_exists?/3 with payment statuses" do
    test "awaiting_payment meetings block their slot from being re-booked" do
      user = insert(:user)
      start_time = ~U[2030-01-01 10:00:00Z]
      end_time = ~U[2030-01-01 10:30:00Z]

      insert(:meeting,
        organizer_user_id: user.id,
        start_time: start_time,
        end_time: end_time,
        status: "awaiting_payment"
      )

      assert MeetingConflictQueries.time_conflict_exists?(start_time, end_time)
    end

    test "expired meetings do not block the slot" do
      user = insert(:user)
      start_time = ~U[2030-01-01 10:00:00Z]
      end_time = ~U[2030-01-01 10:30:00Z]

      insert(:meeting,
        organizer_user_id: user.id,
        start_time: start_time,
        end_time: end_time,
        status: "expired"
      )

      refute MeetingConflictQueries.time_conflict_exists?(start_time, end_time)
    end
  end

  describe "time_conflict_exists?/3 with a pending reschedule request" do
    test "a meeting with reschedule_requested_at set does not block its slot" do
      user = insert(:user)
      start_time = ~U[2030-03-01 10:00:00Z]
      end_time = ~U[2030-03-01 10:30:00Z]

      insert(:meeting,
        organizer_user_id: user.id,
        start_time: start_time,
        end_time: end_time,
        status: "confirmed",
        reschedule_requested_at: DateTime.utc_now()
      )

      refute MeetingConflictQueries.time_conflict_exists?(start_time, end_time)
    end
  end

  describe "count_locked_conflicts/4 with payment statuses" do
    test "awaiting_payment meetings count as conflicts for the same organizer" do
      user = insert(:user)
      start_time = ~U[2030-02-01 10:00:00Z]
      end_time = ~U[2030-02-01 10:30:00Z]

      insert(:meeting,
        organizer_user_id: user.id,
        start_time: start_time,
        end_time: end_time,
        status: "awaiting_payment"
      )

      Repo.transaction(fn ->
        assert {:error, 1} =
                 MeetingConflictQueries.count_locked_conflicts(
                   start_time,
                   end_time,
                   nil,
                   user.id
                 )
      end)
    end

    test "expired meetings are not counted as conflicts" do
      user = insert(:user)
      start_time = ~U[2030-02-01 10:00:00Z]
      end_time = ~U[2030-02-01 10:30:00Z]

      insert(:meeting,
        organizer_user_id: user.id,
        start_time: start_time,
        end_time: end_time,
        status: "expired"
      )

      Repo.transaction(fn ->
        assert {:ok, :no_conflicts} =
                 MeetingConflictQueries.count_locked_conflicts(
                   start_time,
                   end_time,
                   nil,
                   user.id
                 )
      end)
    end

    test "a meeting with reschedule_requested_at set is not counted as a conflict" do
      user = insert(:user)
      start_time = ~U[2030-03-01 10:00:00Z]
      end_time = ~U[2030-03-01 10:30:00Z]

      insert(:meeting,
        organizer_user_id: user.id,
        start_time: start_time,
        end_time: end_time,
        status: "confirmed",
        reschedule_requested_at: DateTime.utc_now()
      )

      Repo.transaction(fn ->
        assert {:ok, :no_conflicts} =
                 MeetingConflictQueries.count_locked_conflicts(
                   start_time,
                   end_time,
                   nil,
                   user.id
                 )
      end)
    end
  end
end
