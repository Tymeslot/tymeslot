defmodule Tymeslot.Workers.CalendarEventWorkerMeetingGoneTest do
  @moduledoc """
  After a successful calendar write the worker reads the meeting again, to
  clear its offline queue tag and, for a create, the organiser's availability
  cache. A meeting deleted while the write was in flight leaves an event on
  the calendar for a booking that no longer exists, so that is logged rather
  than skipped in silence.
  """

  # async: false: one test asserts the absence of a log line, and the
  # capture handler sees every process's events.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :calendar

  import Mox
  import Tymeslot.WorkerTestHelpers

  alias Ecto.UUID
  alias Tymeslot.Test.LogCapture
  alias Tymeslot.Workers.CalendarEventWorker

  setup :verify_on_exit!

  setup do
    LogCapture.attach()
    :ok
  end

  test "logs a warning when the meeting is gone after a successful update" do
    %{meeting: meeting} = setup_calendar_scenario()

    expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _meeting ->
      Repo.delete!(meeting)
      :ok
    end)

    assert :ok =
             perform_job(CalendarEventWorker, %{
               "action" => "update",
               "meeting_id" => meeting.id
             })

    event = LogCapture.await_log("Meeting gone after a successful calendar write")
    assert event.level == :warning
    assert event.meta.meeting_id == meeting.id
    assert event.meta.action == "update"
    assert event.meta.reason == :not_found
  end

  test "stays quiet for a deletion of a meeting that is already gone" do
    assert :ok =
             perform_job(CalendarEventWorker, %{
               "action" => "delete",
               "meeting_id" => UUID.generate()
             })

    messages = Enum.map(LogCapture.drain(), &LogCapture.message_text(&1.msg))
    refute Enum.any?(messages, &(&1 =~ "Meeting gone after a successful calendar write"))
  end
end
