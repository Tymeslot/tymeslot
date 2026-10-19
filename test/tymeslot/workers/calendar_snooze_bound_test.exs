defmodule Tymeslot.Workers.CalendarSnoozeBoundTest do
  @moduledoc """
  From Oban 2.24 a snooze costs no attempt, so a calendar job that waits out
  an open breaker by snoozing would wait for ever if its provider never
  recovered: its owner never told, no alert raised. Each calendar worker
  bounds those waits by the job's own execution count.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :calendar

  import Mox
  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Meetings.CalendarEventSync
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  setup :verify_on_exit!

  describe "a calendar write waiting for an open breaker" do
    setup do
      meeting = insert(:meeting)

      stub(Tymeslot.CalendarMock, :create_event, fn _event_data, _user_id ->
        {:error, :circuit_open}
      end)

      %{args: %{"action" => "create", "meeting_id" => meeting.id}}
    end

    test "snoozes while under the bound", %{args: args} do
      assert {:snooze, _seconds} =
               perform_job(CalendarEventWorker, args, meta: %{"snoozed" => 10})
    end

    test "fails once the bound is reached, so the job can exhaust and alert", %{args: args} do
      assert {:error, reason} =
               perform_job(CalendarEventWorker, args, meta: %{"snoozed" => 11})

      assert reason =~ "did not recover"
    end

    # None of the waiting verdicts reaches the owner email a persistent create
    # failure sends, so the last attempt spent on the bound sends it.
    test "tells the owner when the last attempt ends the wait", %{args: args} do
      meeting_id = args["meeting_id"]

      expect(Tymeslot.EmailServiceMock, :send_calendar_sync_error, fn meeting, _reason ->
        assert meeting.id == meeting_id
        :ok
      end)

      assert {:error, _reason} =
               perform_job(CalendarEventWorker, args,
                 attempt: 5,
                 max_attempts: 5,
                 meta: %{"snoozed" => 11}
               )
    end

    test "tells the owner when a rate limit outlasts the last attempt", %{args: args} do
      stub(Tymeslot.CalendarMock, :create_event, fn _event_data, _user_id ->
        {:error, :rate_limited}
      end)

      expect(Tymeslot.EmailServiceMock, :send_calendar_sync_error, fn _meeting, _reason -> :ok end)

      assert {:error, _reason} =
               perform_job(CalendarEventWorker, args,
                 attempt: 5,
                 max_attempts: 5,
                 meta: %{"snoozed" => 11}
               )
    end

    # The worker waits an open breaker out by snoozing, which costs no
    # attempt, so every wait spent on the last attempt runs the create on
    # that attempt again. Only the end of the wait tells the owner, or each
    # of those waits would send another copy.
    test "does not tell the owner while the last attempt is still waiting", %{args: args} do
      expect(Tymeslot.EmailServiceMock, :send_calendar_sync_error, 0, fn _meeting, _reason ->
        :ok
      end)

      assert {:snooze, _seconds} =
               perform_job(CalendarEventWorker, args, attempt: 5, max_attempts: 5)
    end

    test "does not tell the owner while attempts remain", %{args: args} do
      expect(Tymeslot.EmailServiceMock, :send_calendar_sync_error, 0, fn _meeting, _reason ->
        :ok
      end)

      assert {:error, _reason} =
               perform_job(CalendarEventWorker, args,
                 attempt: 4,
                 max_attempts: 5,
                 meta: %{"snoozed" => 11}
               )
    end
  end

  describe "CalendarEventSync.notify_create_abandoned/2" do
    test "tells the owner of a booking still waiting for its calendar event" do
      meeting = insert(:meeting)

      expect(Tymeslot.EmailServiceMock, :send_calendar_sync_error, fn notified, _reason ->
        assert notified.id == meeting.id
        :ok
      end)

      assert :ok = CalendarEventSync.notify_create_abandoned(meeting.id, "gave up")
    end

    test "sends nothing for a cancelled booking or one that is gone" do
      cancelled = insert(:meeting, status: "cancelled")

      expect(Tymeslot.EmailServiceMock, :send_calendar_sync_error, 0, fn _meeting, _reason ->
        :ok
      end)

      assert :ok = CalendarEventSync.notify_create_abandoned(cancelled.id, "gave up")
      assert :ok = CalendarEventSync.notify_create_abandoned(UUID.generate(), "gave up")
    end
  end

  describe "a Google sync waiting for an open breaker" do
    setup do
      integration =
        insert(:calendar_integration, provider: "google", google_sync_token: "valid-sync-token")

      stub(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :circuit_open}
      end)

      %{args: %{"calendar_integration_id" => integration.id}}
    end

    test "snoozes while under the bound", %{args: args} do
      assert {:snooze, 120} =
               perform_job(SyncGoogleCalendarWorker, args, meta: %{"snoozed" => 10})
    end

    test "fails once the bound is reached", %{args: args} do
      assert {:error, reason} =
               perform_job(SyncGoogleCalendarWorker, args, meta: %{"snoozed" => 11})

      assert reason =~ "did not recover"
    end
  end
end
