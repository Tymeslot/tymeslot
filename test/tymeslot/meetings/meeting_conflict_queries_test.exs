defmodule Tymeslot.Meetings.MeetingConflictQueriesTest do
  @moduledoc false

  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :meetings
  @moduletag :queries

  alias Tymeslot.Meetings.MeetingConflictQueries

  describe "list_live_in_window/4 with payment statuses" do
    test "awaiting_payment meetings are listed for the same organizer" do
      user = insert(:user)
      start_time = ~U[2030-02-01 10:00:00Z]
      end_time = ~U[2030-02-01 10:30:00Z]

      insert(:meeting,
        organizer_user_id: user.id,
        start_time: start_time,
        end_time: end_time,
        status: :awaiting_payment
      )

      assert [%{status: :awaiting_payment}] =
               MeetingConflictQueries.list_live_in_window(user.id, start_time, end_time, nil)
    end

    test "expired meetings are not listed" do
      user = insert(:user)
      start_time = ~U[2030-02-01 10:00:00Z]
      end_time = ~U[2030-02-01 10:30:00Z]

      insert(:meeting,
        organizer_user_id: user.id,
        start_time: start_time,
        end_time: end_time,
        status: :expired
      )

      assert MeetingConflictQueries.list_live_in_window(user.id, start_time, end_time, nil) == []
    end

    test "a meeting with reschedule_requested_at set is not listed" do
      user = insert(:user)
      start_time = ~U[2030-03-01 10:00:00Z]
      end_time = ~U[2030-03-01 10:30:00Z]

      insert(:meeting,
        organizer_user_id: user.id,
        start_time: start_time,
        end_time: end_time,
        status: :confirmed,
        reschedule_requested_at: DateTime.utc_now()
      )

      assert MeetingConflictQueries.list_live_in_window(user.id, start_time, end_time, nil) == []
    end
  end
end
