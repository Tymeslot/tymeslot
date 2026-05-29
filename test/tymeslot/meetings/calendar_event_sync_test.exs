defmodule Tymeslot.Meetings.CalendarEventSyncTest do
  use Tymeslot.DataCase, async: true

  @moduletag :meetings
  @moduletag :integration

  import Mox
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers

  alias Ecto.UUID
  alias Tymeslot.Meetings.CalendarEventSync
  alias Tymeslot.Meetings.MeetingSchema

  setup :verify_on_exit!

  describe "create/2" do
    test "creates a calendar event and persists the integration mapping" do
      %{integration: integration, meeting: meeting} = setup_calendar_scenario()

      expect_calendar_create_success(integration.id)

      assert :ok = CalendarEventSync.create(meeting.id, 1)

      updated_meeting = Repo.get(MeetingSchema, meeting.id)
      assert updated_meeting.calendar_integration_id == integration.id
      assert updated_meeting.calendar_path == "primary"
    end

    test "switches to update when the meeting already carries an external UID" do
      %{integration: integration, meeting: meeting} =
        setup_calendar_scenario(uid: "teams-external-event-xyz")

      uid = meeting.uid

      # No create_event is invoked — the create→update fallback runs update_event.
      expect(Tymeslot.CalendarMock, :update_event, fn ^uid, _data, m ->
        assert m.calendar_integration_id == integration.id
        :ok
      end)

      assert :ok = CalendarEventSync.create(meeting.id, 1)
    end

    test "returns {:error, :meeting_not_found} for a non-existent meeting" do
      assert {:error, :meeting_not_found} = CalendarEventSync.create(UUID.generate(), 1)
    end

    test "maps provider error categories to retryable tuples" do
      meeting = insert(:meeting)

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _ctx -> {:error, :rate_limited} end)
      assert {:error, :rate_limited} = CalendarEventSync.create(meeting.id, 1)
    end

    test "sends an owner notification on the final attempt for a persistent failure" do
      meeting = insert(:meeting)

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _ctx ->
        {:error, "Fatal server error"}
      end)

      expect(Tymeslot.EmailServiceMock, :send_calendar_sync_error, fn _meeting, _reason -> :ok end)

      assert {:error, "Fatal server error"} = CalendarEventSync.create(meeting.id, 5)
    end
  end

  describe "update/2" do
    test "updates an existing event" do
      %{meeting: meeting} = setup_calendar_scenario()
      uid = meeting.uid

      expect(Tymeslot.CalendarMock, :update_event, fn ^uid, _data, _ctx -> :ok end)

      assert :ok = CalendarEventSync.update(meeting.id, 1)
    end

    test "recreates the event when the provider reports it as not found (404 recovery)" do
      %{user: user, integration: integration, meeting: meeting} = setup_calendar_scenario()
      uid = meeting.uid

      expect(Tymeslot.CalendarMock, :update_event, fn ^uid, _data, _ctx ->
        {:error, :not_found}
      end)

      # Recovery path creates against the organizer's user id.
      expect(Tymeslot.CalendarMock, :create_event, fn _data, id ->
        assert id == user.id
        {:ok, "new-uid"}
      end)

      expect(Tymeslot.CalendarMock, :get_booking_integration_info, fn _ctx ->
        {:ok, %{integration_id: integration.id, calendar_path: "primary"}}
      end)

      assert :ok = CalendarEventSync.update(meeting.id, 1)
    end

    test "returns {:error, :meeting_not_found} for a non-existent meeting" do
      assert {:error, :meeting_not_found} = CalendarEventSync.update(UUID.generate(), 1)
    end
  end

  describe "delete/2" do
    test "deletes the event" do
      %{meeting: meeting} = setup_calendar_scenario()
      uid = meeting.uid

      expect(Tymeslot.CalendarMock, :delete_event, fn ^uid, _ctx -> :ok end)

      assert :ok = CalendarEventSync.delete(meeting.id, 1)
    end

    test "treats a not_found event as success (idempotent)" do
      %{meeting: meeting} = setup_calendar_scenario()
      uid = meeting.uid

      expect(Tymeslot.CalendarMock, :delete_event, fn ^uid, _ctx -> {:error, :not_found} end)

      assert :ok = CalendarEventSync.delete(meeting.id, 1)
    end

    test "skips deletion when the meeting has no calendar integration" do
      meeting = insert(:meeting, calendar_integration_id: nil)

      # delete_event must NOT be called — no expectation set, verify_on_exit! enforces it.
      assert :ok = CalendarEventSync.delete(meeting.id, 1)
    end

    test "succeeds even if the meeting does not exist (graceful degradation)" do
      assert :ok = CalendarEventSync.delete(UUID.generate(), 1)
    end
  end

  describe "provider mapping persistence" do
    test "persists Google-style string-key map as provider_event_id" do
      %{meeting: meeting} = setup_calendar_scenario(uid: UUID.generate())

      # Direct create path: create_event returns the raw provider map, which is
      # passed straight to persist_calendar_mapping. Google returns string keys.
      expect(Tymeslot.CalendarMock, :create_event, fn _data, _ctx ->
        {:ok, %{"id" => "google-event-id-abc"}}
      end)

      expect(Tymeslot.CalendarMock, :get_booking_integration_info, fn _ctx ->
        {:ok, %{integration_id: meeting.calendar_integration_id, calendar_path: "primary"}}
      end)

      assert :ok = CalendarEventSync.create(meeting.id, 1)

      updated = Repo.get(MeetingSchema, meeting.id)
      assert updated.provider_event_id == "google-event-id-abc"
    end

    test "persists Outlook-style atom-key map as provider_event_id" do
      %{meeting: meeting} = setup_calendar_scenario(uid: UUID.generate())

      # Outlook returns the common-format map with atom keys.
      expect(Tymeslot.CalendarMock, :create_event, fn _data, _ctx ->
        {:ok, %{id: "outlook-event-id-xyz"}}
      end)

      expect(Tymeslot.CalendarMock, :get_booking_integration_info, fn _ctx ->
        {:ok, %{integration_id: meeting.calendar_integration_id, calendar_path: "primary"}}
      end)

      assert :ok = CalendarEventSync.create(meeting.id, 1)

      updated = Repo.get(MeetingSchema, meeting.id)
      assert updated.provider_event_id == "outlook-event-id-xyz"
    end

    test "persists a plain string UID returned from a direct create" do
      %{integration: integration, meeting: meeting} =
        setup_calendar_scenario(uid: UUID.generate())

      expect_calendar_create_success(integration.id, "caldav-uid-123")

      assert :ok = CalendarEventSync.create(meeting.id, 1)

      updated = Repo.get(MeetingSchema, meeting.id)
      assert updated.uid == "caldav-uid-123"
    end

    test "surfaces {:error, _} when mapping persistence fails" do
      %{integration: integration, meeting: meeting} = setup_calendar_scenario_with_paths()
      external_uid = "collides-#{System.unique_integer([:positive])}"
      original_uid = meeting.uid

      colliding_start = DateTime.add(meeting.start_time, 1, :hour)

      insert(:meeting,
        uid: external_uid,
        calendar_integration_id: integration.id,
        organizer_user_id: meeting.organizer_user_id,
        start_time: colliding_start,
        end_time: DateTime.add(colliding_start, 60, :minute)
      )

      expect_calendar_create_success(integration.id, external_uid)

      assert {:error, :calendar_mapping_persistence_failed} =
               CalendarEventSync.create(meeting.id, 1)

      unchanged = Repo.get!(MeetingSchema, meeting.id)
      assert unchanged.uid == original_uid
    end
  end
end
