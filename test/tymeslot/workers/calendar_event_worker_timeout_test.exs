defmodule Tymeslot.Workers.CalendarEventWorkerTimeoutTest do
  # async: false because the test toggles the global :test_mode flag and puts
  # Mox in global mode (so the Task.Supervisor child process can see the stub).
  # Both would leak into concurrent async tests and break unrelated mocks.
  use Tymeslot.DataCase, async: false

  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Workers.CalendarEventWorker

  setup :verify_on_exit!

  describe "perform/1 - timeout handling" do
    test "snoozes on timeout when CalDAV operation blocks" do
      # Exercises the Task.yield timeout path, which only fires when test_mode
      # is false and the spawned task outlives the calendar timeout. That
      # timeout is 90s in production and read from config, so this lowers it to
      # 50ms rather than waiting out the real one; the branch under test is the
      # same either way, and the wait was previously half of this suite's
      # runtime on its own.
      meeting = insert(:meeting)

      Mox.stub(Tymeslot.CalendarMock, :create_event, fn _event_data, _user_id ->
        # Block indefinitely — Task.yield will time out after 90s
        Process.sleep(:infinity)
      end)

      original_test_mode = Application.get_env(:tymeslot, :test_mode, false)
      Application.put_env(:tymeslot, :test_mode, false)
      Application.put_env(:tymeslot, :calendar_timeout_ms, 50)

      try do
        assert {:snooze, 300} =
                 perform_job(CalendarEventWorker, %{
                   "action" => "create",
                   "meeting_id" => meeting.id
                 })
      after
        Application.put_env(:tymeslot, :test_mode, original_test_mode)
        Application.delete_env(:tymeslot, :calendar_timeout_ms)
      end
    end
  end
end
