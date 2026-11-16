defmodule Tymeslot.Notifications.Email.CalendarSyncEmailsTest do
  @moduledoc """
  The host's notices about what their calendar did to a booking, raised by
  calendar sync code and sent from an email job, so that a failed send is
  retried rather than lost.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :emails
  @moduletag :integration

  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings.CalendarEventSync
  alias Tymeslot.Meetings.ExternalCalendarChanges
  alias Tymeslot.Workers.EmailWorker

  defmodule RaisingAdminAlerts do
    @moduledoc false
    @spec send_alert(term(), term()) :: no_return()
    def send_alert(_event, _payload), do: raise("admin alert failure")
  end

  setup :verify_on_exit!
  setup :capture_admin_alerts

  defp future_meeting(attrs \\ %{}) do
    start_time = DateTime.add(DateTime.utc_now(:second), 2, :day)

    insert(
      :meeting,
      Map.merge(
        %{
          status: :confirmed,
          start_time: start_time,
          end_time: DateTime.add(start_time, 30, :minute)
        },
        attrs
      )
    )
  end

  defp only_job(action) do
    assert [job] = all_enqueued(worker: EmailWorker, args: %{"action" => action})
    job
  end

  describe "a booking moved in the host's external calendar" do
    test "is scheduled, not sent, and the job tells the host" do
      meeting = future_meeting()
      test_pid = self()

      stub(EmailServiceMock, :send_external_booking_change, fn sent, email, discrepancy ->
        send(test_pid, {:notice, sent.id, email, discrepancy})
        {:ok, :sent}
      end)

      assert :ok = ExternalCalendarChanges.apply_change_to_meeting(meeting, :modified)
      refute_received {:notice, _id, _email, _discrepancy}

      job = only_job("send_external_booking_change")
      assert :ok = perform_job(EmailWorker, job.args)

      organizer_email = meeting.organizer_email
      meeting_id = meeting.id
      assert_received {:notice, ^meeting_id, ^organizer_email, :modified}
    end

    test "a failed send fails the job, so Oban retries it" do
      meeting = future_meeting()

      expect(EmailServiceMock, :send_external_booking_change, fn _meeting, _email, _discrepancy ->
        {:error, :smtp_down}
      end)

      assert :ok = ExternalCalendarChanges.apply_change_to_meeting(meeting, :modified)

      job = only_job("send_external_booking_change")
      assert {:error, _reason} = perform_job(EmailWorker, job.args)
    end
  end

  describe "a calendar event that cannot be written" do
    test "alerts the operator at once and tells the owner from a job" do
      meeting = future_meeting()
      test_pid = self()

      stub(EmailServiceMock, :send_calendar_sync_error, fn sent, reason ->
        send(test_pid, {:sync_error, sent.id, reason})
        {:ok, :sent}
      end)

      assert :ok = CalendarEventSync.notify_create_abandoned(meeting.id, :timeout)
      refute_received {:sync_error, _id, _reason}

      meeting_id = meeting.id
      assert_received {:send_alert, :calendar_sync_error, %{meeting_id: ^meeting_id}}

      job = only_job("send_calendar_sync_error")
      assert :ok = perform_job(EmailWorker, job.args)
      assert_received {:sync_error, ^meeting_id, ":timeout"}

      # The alert went out when the failure was known; the job does not repeat it.
      refute_received {:send_alert, :calendar_sync_error, _payload}
    end

    test "an operator alert that fails does not stop the owner being told" do
      meeting = future_meeting()
      with_config(:tymeslot, :admin_alerts_impl, RaisingAdminAlerts)

      capture_log(fn ->
        assert :ok = CalendarEventSync.notify_create_abandoned(meeting.id, :timeout)
      end)

      assert %{args: %{"meeting_id" => meeting_id}} = only_job("send_calendar_sync_error")
      assert meeting_id == meeting.id
    end

    test "a failed send fails the job, so Oban retries it" do
      meeting = future_meeting()

      expect(EmailServiceMock, :send_calendar_sync_error, fn _meeting, _reason ->
        {:error, :smtp_down}
      end)

      assert :ok = CalendarEventSync.notify_create_abandoned(meeting.id, :timeout)

      job = only_job("send_calendar_sync_error")
      assert {:error, _reason} = perform_job(EmailWorker, job.args)
    end
  end
end
