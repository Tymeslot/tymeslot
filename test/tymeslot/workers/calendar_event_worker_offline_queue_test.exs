defmodule Tymeslot.Workers.CalendarEventWorkerOfflineQueueTest do
  @moduledoc """
  How `CalendarEventWorker` interacts with the offline write queue: failed
  writes tag the provider cache row for replay, and successful ones clear it.
  The remaining worker behaviour is covered by `CalendarEventWorkerTest`.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Workers.CalendarEventWorker

  setup :verify_on_exit!

  describe "perform/1 - offline queue integration" do
    # These tests require the integration to have at least one calendar_paths entry
    # so that QueueWiring.tag/3 can write a non-null provider_calendar_id to the
    # provider_calendar_events table.

    test "failed create job tags the cache row as locally_created" do
      %{integration: integration, meeting: meeting} =
        setup_calendar_scenario_with_paths()

      expect(Tymeslot.CalendarMock, :create_event, fn _event_data, _context ->
        {:error, :server_error}
      end)

      # A non-final attempt so no email notification mock is needed
      assert {:error, :server_error} =
               perform_job(
                 CalendarEventWorker,
                 %{"action" => "create", "meeting_id" => meeting.id},
                 attempt: 1
               )

      assert {:ok, cache_row} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, meeting.calendar_uid)

      assert cache_row.sync_state == "locally_created"
    end

    test "failed update job tags the cache row as locally_modified" do
      %{integration: integration, meeting: meeting} =
        setup_calendar_scenario_with_paths()

      uid = meeting.calendar_uid

      expect(Tymeslot.CalendarMock, :update_event, fn ^uid, _data, _meeting ->
        {:error, :server_error}
      end)

      assert {:error, :server_error} =
               perform_job(
                 CalendarEventWorker,
                 %{"action" => "update", "meeting_id" => meeting.id},
                 attempt: 1
               )

      assert {:ok, cache_row} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, meeting.calendar_uid)

      assert cache_row.sync_state == "locally_modified"
    end

    test "a 412 conflict discards the job and hands the write to the offline queue" do
      %{integration: integration, meeting: meeting} =
        setup_calendar_scenario_with_paths()

      uid = meeting.calendar_uid

      # A 412 means the server's ETag moved on. Replaying the identical
      # conditional PUT fails the same way every time, so the job must stop
      # after one attempt rather than spend five and raise an admin alert.
      expect(Tymeslot.CalendarMock, :update_event, fn ^uid, _data, _meeting ->
        {:error, :precondition_failed}
      end)

      assert {:discard, reason} =
               perform_job(
                 CalendarEventWorker,
                 %{"action" => "update", "meeting_id" => meeting.id},
                 attempt: 1
               )

      assert reason =~ "offline replay"

      # Discarding is only safe because the write is already queued: the offline
      # queue replays it on the next sync under the row's conflict policy.
      assert {:ok, cache_row} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, meeting.calendar_uid)

      assert cache_row.sync_state == "locally_modified"
    end

    test "a 412 on a create retries instead of discarding" do
      meeting = insert(:meeting)

      # `If-None-Match: *` found an event already at the UID, so the create
      # switches to an update, and here that update conflicts too. The offline
      # queue replays creates without a conflict policy, so discarding here
      # would loop silently forever; the ordinary retry path must keep the job
      # (and its exhaustion alert).
      expect(Tymeslot.CalendarMock, :create_event, fn _event_data, _user_id ->
        {:error, :precondition_failed}
      end)

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _event_data, _meeting ->
        {:error, :precondition_failed}
      end)

      assert {:error, :precondition_failed} =
               perform_job(
                 CalendarEventWorker,
                 %{"action" => "create", "meeting_id" => meeting.id},
                 attempt: 1
               )
    end

    test "failed delete job tags the cache row as locally_deleted" do
      %{integration: integration, meeting: meeting} =
        setup_calendar_scenario_with_paths()

      {:ok, meeting} = MeetingQueries.update_meeting(meeting, %{status: "cancelled"})
      uid = meeting.calendar_uid

      expect(Tymeslot.CalendarMock, :delete_event, fn ^uid, _meeting ->
        {:error, :server_error}
      end)

      assert {:error, :server_error} =
               perform_job(
                 CalendarEventWorker,
                 %{"action" => "delete", "meeting_id" => meeting.id},
                 attempt: 1
               )

      assert {:ok, cache_row} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, meeting.calendar_uid)

      assert cache_row.sync_state == "locally_deleted"
    end

    test "provider-success + mapping-persistence failure surfaces as {:error, _}" do
      # The provider has created the event on its side and returned a UID,
      # but MeetingQueries.update_meeting then fails — a silent `:ok` here
      # would leave the remote event dangling with no local reference, so
      # the worker must surface {:error, _} to let Oban retry.
      #
      # We force the update failure by seeding a *second* meeting that
      # already owns the UID the provider returns. The unique_constraint
      # on meetings.calendar_uid makes the changeset invalid when we try to
      # write the same UID onto the meeting under test.
      %{integration: integration, meeting: meeting} = setup_calendar_scenario_with_paths()
      external_uid = "collides-#{System.unique_integer([:positive])}"
      original_uid = meeting.uid
      original_calendar_uid = meeting.calendar_uid

      # Offset start_time so we don't also trip the
      # `unique_confirmed_meeting_per_organizer_at_time` constraint — we want
      # the uid collision to be the failure, not a calendar-time clash.
      colliding_start = DateTime.add(meeting.start_time, 1, :hour)

      insert(:meeting,
        calendar_uid: external_uid,
        calendar_integration_id: integration.id,
        organizer_user_id: meeting.organizer_user_id,
        start_time: colliding_start,
        end_time: DateTime.add(colliding_start, 60, :minute)
      )

      expect_calendar_create_success(integration.id, external_uid)

      # The provider event was created but mapping persistence fails on the UID
      # unique constraint. The orphaned provider event must be deleted before the
      # error is surfaced so a retry doesn't produce a duplicate.
      expect(Tymeslot.CalendarMock, :delete_event, fn ^external_uid, _ctx -> :ok end)

      assert {:error, :calendar_mapping_persistence_failed} =
               perform_job(CalendarEventWorker, %{
                 "action" => "create",
                 "meeting_id" => meeting.id
               })

      # UID on the meeting under test is untouched — no half-written mapping.
      unchanged = Repo.get!(MeetingSchema, meeting.id)
      assert unchanged.uid == original_uid
      assert unchanged.calendar_uid == original_calendar_uid
    end

    test "successful create job clears a pre-existing offline queue row" do
      # The create mock returns this external uid, which persist_calendar_mapping
      # writes back to the meeting.  clear_offline_queue_tag then fetches the
      # updated meeting (calendar_uid = external_uid) and clears the matching
      # cache row.
      external_uid = "caldav-event-clear-test"

      %{integration: integration, meeting: meeting} =
        setup_calendar_scenario_with_paths()

      # Pre-seed the queue row using the external uid that the create mock will
      # return — this simulates a failed write from a previous sync cycle.
      # The factory defaults to provider "google" so we override provider and
      # provider_calendar_id to satisfy the NOT NULL constraint.
      insert(:provider_calendar_event,
        uid: external_uid,
        calendar_integration: integration,
        provider: "caldav",
        provider_calendar_id: "primary",
        sync_state: "locally_created"
      )

      expect_calendar_create_success(integration.id, external_uid)

      assert :ok =
               perform_job(CalendarEventWorker, %{
                 "action" => "create",
                 "meeting_id" => meeting.id
               })

      assert {:ok, cache_row} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, external_uid)

      assert cache_row.sync_state == "synced"
    end
  end
end
