defmodule Tymeslot.Workers.CalendarEventWorkerTimeoutTest do
  # async: false because the test lowers the global calendar timeout.
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
      # The calendar timeout is 90s in production and read from config, so
      # this lowers it to 50ms rather than waiting out the real one; the
      # branch under test is the same either way.
      meeting = insert(:meeting)

      Mox.stub(Tymeslot.CalendarMock, :create_event, fn _event_data, _user_id ->
        # Block indefinitely — Task.yield will time out after 90s
        Process.sleep(:infinity)
      end)

      Application.put_env(:tymeslot, :calendar_timeout_ms, 50)

      try do
        assert {:snooze, 300} =
                 perform_job(CalendarEventWorker, %{
                   "action" => "create",
                   "meeting_id" => meeting.id
                 })
      after
        Application.delete_env(:tymeslot, :calendar_timeout_ms)
      end
    end
  end

  # `MeetingProvisioning.booking_online_meeting/1` counts on a run recording
  # nothing once `attempt_timeout_ms/0` has passed: a create still running
  # after it could record an event carrying a Teams meeting after the Teams
  # job has made one of its own.
  describe "attempt_timeout_ms/0 bounds a run" do
    test "a run's calendar work is stopped at the deadline, not left running" do
      meeting = insert(:meeting)
      test_pid = self()

      Mox.stub(Tymeslot.CalendarMock, :create_event, fn _event_data, _user_id ->
        send(test_pid, {:calendar_call, self()})
        Process.sleep(:infinity)
      end)

      Application.put_env(:tymeslot, :calendar_timeout_ms, 50)

      try do
        assert CalendarEventWorker.attempt_timeout_ms() == 50

        assert {:snooze, _seconds} =
                 perform_job(CalendarEventWorker, %{
                   "action" => "create",
                   "meeting_id" => meeting.id
                 })
      after
        Application.delete_env(:tymeslot, :calendar_timeout_ms)
      end

      assert_received {:calendar_call, call_pid}
      refute Process.alive?(call_pid)
    end

    # An Oban timeout would kill the job but not the unlinked task running
    # its work, which could then record an event past the deadline.
    test "sets no Oban timeout that could stop the job before the run's own deadline" do
      assert CalendarEventWorker.timeout(%Oban.Job{args: %{}}) == :infinity
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

      CaptureLog.capture_log(fn ->
        assert {:error, message} =
                 perform_job(CalendarEventWorker, %{
                   "action" => "create",
                   "meeting_id" => meeting.id
                 })

        send(self(), {:message, message})
      end)

      assert_received {:message, message}
      assert message =~ "Calendar operation crashed"
      assert message =~ "request_failed"
      refute message =~ "c2VjcmV0LWNhbGRhdg"
    end
  end
end
