defmodule Tymeslot.Workers.CalendarEventWorkerTest do
  use Tymeslot.DataCase, async: true

  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers

  alias Ecto.UUID
  alias Tymeslot.Integrations.Calendar.CalendarEventScheduler
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Workers.CalendarEventWorker

  setup :verify_on_exit!

  describe "perform/1 - create action" do
    test "successfully creates a calendar event" do
      %{integration: integration, meeting: meeting} = setup_calendar_scenario()

      # Mock the event creation and post-creation integration info fetch
      # Note: get_booking_integration_info is called AFTER create_event succeeds
      # to persist which calendar was used
      expect_calendar_create_success(integration.id)

      assert :ok =
               perform_job(CalendarEventWorker, %{
                 "action" => "create",
                 "meeting_id" => meeting.id
               })

      # Verify meeting was updated with integration info
      updated_meeting = Repo.get(MeetingSchema, meeting.id)
      assert updated_meeting.calendar_integration_id == integration.id
      assert updated_meeting.calendar_path == "primary"
    end

    test "handles rate limiting by snoozing with exponential backoff" do
      meeting = insert(:meeting)

      expect(Tymeslot.CalendarMock, :create_event, fn _event_data, _user_id ->
        {:error, :rate_limited}
      end)

      # First attempt - should snooze for 60 seconds (60 * attempt 1)
      assert {:snooze, snooze_seconds} =
               perform_job(
                 CalendarEventWorker,
                 %{
                   "action" => "create",
                   "meeting_id" => meeting.id
                 },
                 attempt: 1
               )

      # Rate limit snooze is min(300, 60 * attempt)
      assert snooze_seconds == 60

      # Third attempt - should snooze for 180 seconds (60 * attempt 3)
      expect(Tymeslot.CalendarMock, :create_event, fn _event_data, _user_id ->
        {:error, :rate_limited}
      end)

      assert {:snooze, snooze_seconds_3} =
               perform_job(
                 CalendarEventWorker,
                 %{
                   "action" => "create",
                   "meeting_id" => meeting.id
                 },
                 attempt: 3
               )

      assert snooze_seconds_3 == 180
    end

    test "discards on unauthorized" do
      meeting = insert(:meeting)

      expect(Tymeslot.CalendarMock, :create_event, fn _event_data, _user_id ->
        {:error, :unauthorized}
      end)

      assert {:discard, "Authentication failed"} =
               perform_job(CalendarEventWorker, %{
                 "action" => "create",
                 "meeting_id" => meeting.id
               })
    end

    test "sends notification on final failure" do
      meeting = insert(:meeting)

      expect(Tymeslot.CalendarMock, :create_event, fn _event_data, _user_id ->
        {:error, "Fatal server error"}
      end)

      expect(Tymeslot.EmailServiceMock, :send_calendar_sync_error, fn _meeting, _reason ->
        :ok
      end)

      # Final attempt is 5
      assert {:error, "Fatal server error"} =
               perform_job(
                 CalendarEventWorker,
                 %{
                   "action" => "create",
                   "meeting_id" => meeting.id
                 },
                 attempt: 5
               )
    end
  end

  describe "perform/1 - input validation" do
    test "handles missing meeting_id" do
      # Missing meeting_id should cause an error (caught by pattern match failure)
      assert_raise FunctionClauseError, fn ->
        perform_job(CalendarEventWorker, %{"action" => "create"})
      end
    end

    test "handles malformed meeting_id (string when UUID expected)" do
      # String meeting_id that's not a valid UUID will cause a CastError in DB query
      result =
        perform_job(CalendarEventWorker, %{
          "action" => "create",
          "meeting_id" => "not-a-number"
        })

      # Worker discards jobs for non-existent meetings
      assert {:discard, "Meeting not found"} = result
    end

    test "handles negative meeting_id (invalid for binary_id)" do
      # Negative integer when binary_id (UUID) expected will cause a CastError in DB query
      result =
        perform_job(CalendarEventWorker, %{
          "action" => "create",
          "meeting_id" => -1
        })

      # Worker discards jobs for non-existent meetings
      assert {:discard, "Meeting not found"} = result
    end

    test "handles missing action" do
      meeting = insert(:meeting)

      assert_raise FunctionClauseError, fn ->
        perform_job(CalendarEventWorker, %{"meeting_id" => meeting.id})
      end
    end

    test "handles unknown action" do
      meeting = insert(:meeting)

      assert {:discard, "Unknown action: invalid"} =
               perform_job(CalendarEventWorker, %{
                 "action" => "invalid",
                 "meeting_id" => meeting.id
               })
    end

    test "handles non-existent meeting gracefully (with valid UUID)" do
      # Use a valid UUID that doesn't exist
      non_existent_uuid = UUID.generate()

      result =
        perform_job(CalendarEventWorker, %{
          "action" => "create",
          "meeting_id" => non_existent_uuid
        })

      assert {:discard, "Meeting not found"} = result
    end

    test "handles missing calendar integration on update" do
      meeting = insert(:meeting, calendar_integration_id: nil)
      uid = meeting.uid

      # Should attempt update with nil integration_id
      expect(Tymeslot.CalendarMock, :update_event, fn ^uid, _data, meeting ->
        assert meeting.calendar_integration_id == nil
        {:error, :not_found}
      end)

      # When not found, it tries to create
      expect(Tymeslot.CalendarMock, :create_event, fn _data, _user_id ->
        {:ok, "new-uid"}
      end)

      # persist_calendar_mapping is called after create — no integration so it returns error
      expect(Tymeslot.CalendarMock, :get_booking_integration_info, fn _meeting ->
        {:error, :not_found}
      end)

      assert :ok =
               perform_job(CalendarEventWorker, %{
                 "action" => "update",
                 "meeting_id" => meeting.id
               })
    end
  end

  describe "perform/1 - update action" do
    test "updates existing event" do
      %{meeting: meeting} = setup_calendar_scenario()
      uid = meeting.uid

      expect(Tymeslot.CalendarMock, :update_event, fn ^uid, _data, _id -> :ok end)

      assert :ok =
               perform_job(CalendarEventWorker, %{
                 "action" => "update",
                 "meeting_id" => meeting.id
               })
    end

    test "creates new event if not found during update" do
      %{user: user, integration: integration, meeting: meeting} = setup_calendar_scenario()
      uid = meeting.uid

      # Update fails with not_found
      expect(Tymeslot.CalendarMock, :update_event, fn ^uid, _data, meeting ->
        assert meeting.calendar_integration_id == integration.id
        {:error, :not_found}
      end)

      # Falls back to creating new event
      expect(Tymeslot.CalendarMock, :create_event, fn _data, id ->
        assert id == user.id
        {:ok, "new-uid"}
      end)

      # persist_calendar_mapping is called after create to save the new UID
      expect(Tymeslot.CalendarMock, :get_booking_integration_info, fn _meeting ->
        {:ok, %{integration_id: integration.id, calendar_path: "primary"}}
      end)

      assert :ok =
               perform_job(CalendarEventWorker, %{
                 "action" => "update",
                 "meeting_id" => meeting.id
               })
    end
  end

  describe "perform/1 - delete action" do
    # Deletion is only ever scheduled once the meeting's slot has already
    # been voided (cancellation, or a pending reschedule request) — mirror
    # that here so `CalendarEventSync.delete/2`'s `expects_calendar_event?/1`
    # guard doesn't skip these as stale.
    test "deletes event" do
      %{meeting: meeting} = setup_calendar_scenario()
      {:ok, meeting} = MeetingQueries.update_meeting(meeting, %{status: "cancelled"})
      uid = meeting.uid

      expect(Tymeslot.CalendarMock, :delete_event, fn ^uid, _id -> :ok end)

      assert :ok =
               perform_job(CalendarEventWorker, %{
                 "action" => "delete",
                 "meeting_id" => meeting.id
               })
    end

    test "considers not_found as success for deletion (idempotent)" do
      %{integration: integration, meeting: meeting} = setup_calendar_scenario()
      {:ok, meeting} = MeetingQueries.update_meeting(meeting, %{status: "cancelled"})
      uid = meeting.uid

      expect(Tymeslot.CalendarMock, :delete_event, fn ^uid, meeting ->
        assert meeting.calendar_integration_id == integration.id
        {:error, :not_found}
      end)

      assert :ok =
               perform_job(CalendarEventWorker, %{
                 "action" => "delete",
                 "meeting_id" => meeting.id
               })
    end

    test "succeeds even if meeting not found (graceful degradation)" do
      # Meeting doesn't exist, but deletion should still succeed
      # Use a valid UUID that doesn't exist
      non_existent_uuid = UUID.generate()

      assert :ok =
               perform_job(CalendarEventWorker, %{
                 "action" => "delete",
                 "meeting_id" => non_existent_uuid
               })
    end
  end

  describe "perform/1 - idempotency and concurrency" do
    test "duplicate creation is safe (idempotent)" do
      %{integration: integration, meeting: meeting} = setup_calendar_scenario()

      # First call: switches from UUID to external ID
      expect(Tymeslot.CalendarMock, :create_event, 1, fn _event_data, _user_id ->
        {:ok, "remote-uid-123"}
      end)

      expect(Tymeslot.CalendarMock, :get_booking_integration_info, 1, fn _user_id ->
        {:ok, %{integration_id: integration.id, calendar_path: "primary"}}
      end)

      # Second call: meeting now has "remote-uid-123", so it's an update
      expect(Tymeslot.CalendarMock, :update_event, 1, fn "remote-uid-123", _data, meeting ->
        assert meeting.calendar_integration_id == integration.id
        :ok
      end)

      # Execute twice - should not cause errors
      assert :ok =
               perform_job(CalendarEventWorker, %{
                 "action" => "create",
                 "meeting_id" => meeting.id
               })

      assert :ok =
               perform_job(CalendarEventWorker, %{
                 "action" => "create",
                 "meeting_id" => meeting.id
               })

      # Meeting should have integration info from last execution
      updated_meeting = Repo.get(MeetingSchema, meeting.id)
      assert updated_meeting.calendar_integration_id == integration.id
      assert updated_meeting.uid == "remote-uid-123"
    end
  end

  describe "perform/1 - migration safety" do
    test "handles job with unknown fields (forward compatibility)" do
      %{integration: integration, meeting: meeting} = setup_calendar_scenario()

      # Initial creation
      expect(Tymeslot.CalendarMock, :create_event, 1, fn _event_data, _user_id ->
        {:ok, "remote-uid-future"}
      end)

      expect(Tymeslot.CalendarMock, :get_booking_integration_info, 1, fn _user_id ->
        {:ok, %{integration_id: integration.id, calendar_path: "primary"}}
      end)

      # Job contains a field from a future version
      assert :ok =
               perform_job(CalendarEventWorker, %{
                 "action" => "create",
                 "meeting_id" => meeting.id,
                 "future_field" => "unknown_value",
                 "priority" => "high"
               })
    end
  end

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
               ProviderCalendarEventQueries.get_by_uid(integration.id, meeting.uid)

      assert cache_row.sync_state == "locally_created"
    end

    test "failed update job tags the cache row as locally_modified" do
      %{integration: integration, meeting: meeting} =
        setup_calendar_scenario_with_paths()

      uid = meeting.uid

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
               ProviderCalendarEventQueries.get_by_uid(integration.id, meeting.uid)

      assert cache_row.sync_state == "locally_modified"
    end

    test "a 412 conflict discards the job and hands the write to the offline queue" do
      %{integration: integration, meeting: meeting} =
        setup_calendar_scenario_with_paths()

      uid = meeting.uid

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
               ProviderCalendarEventQueries.get_by_uid(integration.id, meeting.uid)

      assert cache_row.sync_state == "locally_modified"
    end

    test "a 412 on a create retries instead of discarding" do
      meeting = insert(:meeting)

      # On a create the 412 comes from `If-None-Match: *` finding an event
      # already at the UID. The offline queue replays creates without a
      # conflict policy, so discarding here would loop silently forever;
      # the ordinary retry path must keep the job (and its exhaustion alert).
      expect(Tymeslot.CalendarMock, :create_event, fn _event_data, _user_id ->
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
      uid = meeting.uid

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
               ProviderCalendarEventQueries.get_by_uid(integration.id, meeting.uid)

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
      # on meetings.uid makes the changeset invalid when we try to write
      # the same UID onto the meeting under test.
      %{integration: integration, meeting: meeting} = setup_calendar_scenario_with_paths()
      external_uid = "collides-#{System.unique_integer([:positive])}"
      original_uid = meeting.uid

      # Offset start_time so we don't also trip the
      # `unique_confirmed_meeting_per_organizer_at_time` constraint — we want
      # the uid collision to be the failure, not a calendar-time clash.
      colliding_start = DateTime.add(meeting.start_time, 1, :hour)

      insert(:meeting,
        uid: external_uid,
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
    end

    test "successful create job clears a pre-existing offline queue row" do
      # The create mock returns this external uid, which persist_calendar_mapping
      # writes back to the meeting.  clear_offline_queue_tag then fetches the
      # updated meeting (uid = external_uid) and clears the matching cache row.
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

  describe "scheduling" do
    test "schedule_calendar_creation/1 enqueues job" do
      assert :ok = CalendarEventScheduler.schedule_calendar_creation(123)

      assert_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "create", "meeting_id" => 123}
      )
    end

    test "schedule_calendar_update/1 enqueues job" do
      assert {:ok, _result} = CalendarEventScheduler.schedule_calendar_update(123)

      assert_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "update", "meeting_id" => 123}
      )
    end

    test "schedule_calendar_deletion/1 enqueues job" do
      assert {:ok, _result} = CalendarEventScheduler.schedule_calendar_deletion(123)

      assert_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "delete", "meeting_id" => 123}
      )
    end
  end
end
