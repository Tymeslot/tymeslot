defmodule Tymeslot.Workers.CalendarEventWorkerTest do
  use Tymeslot.DataCase, async: true

  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.UUID
  alias Tymeslot.DatabaseSchemas.MeetingSchema
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
    test "deletes event" do
      %{meeting: meeting} = setup_calendar_scenario()
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

  describe "perform/1 - timeout handling" do
    @tag timeout: 150_000
    test "snoozes on timeout when CalDAV operation blocks" do
      # This test exercises the Task.yield timeout path, which only fires when
      # test_mode is false and the spawned task exceeds @calendar_timeout_ms (90s).
      # It takes ~90 seconds to run because the timeout is a compiled constant.
      pid = self()
      Sandbox.mode(Tymeslot.Repo, {:shared, pid})

      meeting = insert(:meeting)

      # Switch to global mock mode so the Task.Supervisor child process can
      # see the stub. Global mode is safe here because Sandbox is in shared mode.
      Mox.set_mox_global()

      Mox.stub(Tymeslot.CalendarMock, :create_event, fn _event_data, _user_id ->
        # Block indefinitely — Task.yield will time out after 90s
        Process.sleep(:infinity)
      end)

      original_test_mode = Application.get_env(:tymeslot, :test_mode, false)
      Application.put_env(:tymeslot, :test_mode, false)

      try do
        assert {:snooze, 300} =
                 perform_job(CalendarEventWorker, %{
                   "action" => "create",
                   "meeting_id" => meeting.id
                 })
      after
        Application.put_env(:tymeslot, :test_mode, original_test_mode)
        Mox.set_mox_private()
      end
    end
  end

  describe "scheduling" do
    test "schedule_calendar_creation/1 enqueues job" do
      assert :ok = CalendarEventWorker.schedule_calendar_creation(123)

      assert_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "create", "meeting_id" => 123}
      )
    end

    test "schedule_calendar_update/1 enqueues job" do
      assert {:ok, _result} = CalendarEventWorker.schedule_calendar_update(123)

      assert_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "update", "meeting_id" => 123}
      )
    end

    test "schedule_calendar_deletion/1 enqueues job" do
      assert {:ok, _result} = CalendarEventWorker.schedule_calendar_deletion(123)

      assert_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "delete", "meeting_id" => 123}
      )
    end
  end
end
