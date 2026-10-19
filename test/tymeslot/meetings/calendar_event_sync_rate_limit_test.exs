defmodule Tymeslot.Meetings.CalendarEventSyncRateLimitTest do
  @moduledoc """
  A provider's rate limit is waited out, not reported: the worker snoozes for
  it, and a snooze keeps the job's attempt where it was, so a rate limit on
  the last attempt must not read as the persistent failure the owner is
  emailed about.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :meetings
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Meetings.CalendarEventSync

  setup :verify_on_exit!

  # A rate limit that names its wait is waited out by the worker's snooze,
  # which keeps the attempt where it was; it is not a persistent failure.
  test "sends no owner notification for a rate limit on the final attempt" do
    meeting = insert(:meeting)

    expect(Tymeslot.CalendarMock, :create_event, fn _data, _ctx ->
      {:error, {:rate_limited, 30}}
    end)

    expect(Tymeslot.EmailServiceMock, :send_calendar_sync_error, 0, fn _meeting, _reason ->
      :ok
    end)

    assert {:error, {:rate_limited, 30}} = CalendarEventSync.create(meeting.id, 5)
  end
end
