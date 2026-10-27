defmodule Tymeslot.Meetings.CalendarEventSyncStaleUpdateTest do
  @moduledoc """
  A calendar update runs after whatever happened to its meeting since it was
  scheduled, and an update recreates an event it cannot find.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :meetings
  @moduletag :integration

  import Mox
  import Tymeslot.WorkerTestHelpers

  alias Tymeslot.Meetings.CalendarEventSync
  alias Tymeslot.Meetings.MeetingQueries

  setup :verify_on_exit!

  # The cancellation deleted the event.
  test "leaves the event of a meeting cancelled since the update was scheduled alone" do
    %{meeting: meeting} = setup_calendar_scenario()
    {:ok, _cancelled} = MeetingQueries.update_meeting(meeting, %{status: "cancelled"})

    # Any calendar call would fail the test: none is expected.
    assert :ok = CalendarEventSync.update(meeting.id, 1)
  end
end
