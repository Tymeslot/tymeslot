defmodule TymeslotWeb.Dashboard.CalendarGrid.LeftoverWritesTest do
  @moduledoc """
  A calendar grid whose LiveView goes at the end of a test leaves its write
  guardian and the write it is waiting on running under the application's
  supervisors. The cleanup every sandboxed test registers
  (`Tymeslot.Test.LeftoverProcesses`) has to find and stop both, or they
  go on writing into whichever test runs next.

  The calendar mock holds every write until the test releases it, so a
  write is still in flight when the cleanup runs.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  @write_timeout 5_000

  import TymeslotWeb.CalendarGridWriteHelpers

  alias Tymeslot.CalendarGrid.WriteGuardian
  alias Tymeslot.Test.LeftoverProcesses

  setup :hold_writes

  test "the guardian and its write in flight are stopped, and write nothing more", %{
    conn: conn,
    integration: integration
  } do
    lv = open_event(conn, standup(integration, "Team Standup", "Room 101"))

    edit(lv, "update_event_title", "First title")
    edit(lv, "update_event_location", "Room 9")
    assert_receive {:write_started, write, _uid, %{summary: "First title"}}, @write_timeout

    guardian = WriteGuardian.whereis(lv.pid)
    assert is_pid(guardian)

    # The LiveView goes, as it does when the test ends; the guardian takes
    # over the queue, with the second edit still to write.
    kill(lv)
    assert Process.alive?(guardian)
    assert Process.alive?(write)

    :ok = LeftoverProcesses.kill_processes_of(self())

    refute Process.alive?(guardian)
    refute Process.alive?(write)
    refute_receive {:write_started, _pid, _uid, _payload}, 200
  end
end
