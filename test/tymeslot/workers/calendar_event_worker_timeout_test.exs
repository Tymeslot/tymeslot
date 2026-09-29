defmodule Tymeslot.Workers.CalendarEventWorkerTimeoutTest do
  # async: false because the test toggles the global :test_mode flag and puts
  # Mox in global mode (so the Task.Supervisor child process can see the stub).
  # Both would leak into concurrent async tests and break unrelated mocks.
  use Tymeslot.DataCase, async: false

  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.Factory

  alias ExUnit.CaptureLog
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

  describe "perform/1 - a crashed calendar operation" do
    # The job's error is stored in `oban_jobs.errors` and logged by Oban, so
    # the crash reason in it must not carry the credentials a CalDAV client
    # holds, such as its basic-auth header.
    test "returns an error with credentials redacted" do
      meeting = insert(:meeting)

      Mox.stub(Tymeslot.CalendarMock, :create_event, fn _event_data, _user_id ->
        exit({:request_failed, %{"authorization" => "Basic c2VjcmV0LWNhbGRhdg=="}})
      end)

      original_test_mode = Application.get_env(:tymeslot, :test_mode, false)
      Application.put_env(:tymeslot, :test_mode, false)

      # The task is linked, so its exit would kill this process before the
      # worker reads it; trapping exits is what lets the crash reach the
      # worker's `{:exit, reason}` branch.
      Process.flag(:trap_exit, true)

      try do
        CaptureLog.capture_log(fn ->
          assert {:error, message} =
                   perform_job(CalendarEventWorker, %{
                     "action" => "create",
                     "meeting_id" => meeting.id
                   })

          send(self(), {:message, message})
        end)
      after
        Application.put_env(:tymeslot, :test_mode, original_test_mode)
      end

      assert_received {:message, message}
      assert message =~ "Calendar operation crashed"
      assert message =~ "request_failed"
      refute message =~ "c2VjcmV0LWNhbGRhdg"
    end
  end
end
