defmodule Tymeslot.Meetings.CalendarEventSyncTest do
  use Tymeslot.DataCase, async: true

  @moduletag :meetings
  @moduletag :integration

  import Mox
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers

  alias Ecto.UUID
  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Meetings.CalendarEventSync
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias TymeslotWeb.Themes.Core.MeetingManagement

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

    test "switches to update when provider_event_id is already persisted" do
      provider_event_id = "google-event-existing"

      %{meeting: meeting} =
        setup_calendar_scenario(uid: UUID.generate())

      {:ok, meeting} =
        MeetingQueries.update_meeting(meeting, %{provider_event_id: provider_event_id})

      expect(Tymeslot.CalendarMock, :update_event, fn ^provider_event_id, _data, _ctx -> :ok end)

      assert :ok = CalendarEventSync.create(meeting.id, 2)
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

    test "uses provider_event_id after create while preserving meeting.uid" do
      provider_event_id = "google-event-created"
      %{meeting: meeting} = setup_calendar_scenario(uid: UUID.generate())
      original_uid = meeting.uid

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _ctx ->
        {:ok, %{uid: provider_event_id}}
      end)

      expect(Tymeslot.CalendarMock, :get_booking_integration_info, fn _ctx ->
        {:ok, %{integration_id: meeting.calendar_integration_id, calendar_path: "primary"}}
      end)

      assert :ok = CalendarEventSync.create(meeting.id, 1)

      expect(Tymeslot.CalendarMock, :update_event, fn ^provider_event_id, _data, _ctx -> :ok end)

      assert :ok = CalendarEventSync.update(meeting.id, 1)
      assert Repo.get!(MeetingSchema, meeting.id).uid == original_uid
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
        {:ok, %{"uid" => "new-google-event-id"}}
      end)

      expect(Tymeslot.CalendarMock, :get_booking_integration_info, fn _ctx ->
        {:ok, %{integration_id: integration.id, calendar_path: "primary"}}
      end)

      assert :ok = CalendarEventSync.update(meeting.id, 1)

      updated = Repo.get!(MeetingSchema, meeting.id)
      assert updated.uid == uid
      assert updated.provider_event_id == "new-google-event-id"
    end

    test "returns {:error, :meeting_not_found} for a non-existent meeting" do
      assert {:error, :meeting_not_found} = CalendarEventSync.update(UUID.generate(), 1)
    end
  end

  describe "update/2 cache write-through (reschedule cache staleness fix)" do
    test "writes the new time through to the linked CalDAV cache row and broadcasts it" do
      %{integration: integration, meeting: meeting} = setup_calendar_scenario()

      stale_start = DateTime.add(meeting.start_time, -3600, :second)
      stale_end = DateTime.add(meeting.end_time, -3600, :second)

      cached =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          provider: "caldav",
          uid: meeting.uid,
          provider_event_id: nil,
          summary: "Old title",
          start_at: stale_start,
          end_at: stale_end
        )

      Phoenix.PubSub.subscribe(Tymeslot.PubSub, "calendar_events:#{meeting.organizer_user_id}")

      expect_calendar_update_success()

      assert :ok = CalendarEventSync.update(meeting.id, 1)

      reloaded = Repo.get!(cached.__struct__, cached.id)
      assert DateTime.compare(reloaded.start_at, meeting.start_time) == :eq
      assert DateTime.compare(reloaded.end_at, meeting.end_time) == :eq
      assert reloaded.summary == meeting.title

      assert_receive {:calendar_events_updated, user_id, uids}
      assert user_id == meeting.organizer_user_id
      assert meeting.uid in uids
    end

    test "writes through by provider_event_id for OAuth-linked meetings, not uid" do
      provider_event_id = "google-event-reschedule"

      %{integration: integration, meeting: meeting} =
        setup_calendar_scenario(uid: UUID.generate())

      {:ok, meeting} =
        MeetingQueries.update_meeting(meeting, %{provider_event_id: provider_event_id})

      # The cache row's own `uid` is the provider's iCalUID, which is a
      # different value than the Tymeslot-generated `meeting.uid` for OAuth
      # providers — only `provider_event_id` links the two.
      cached =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          provider: "google",
          uid: "google-ical-uid-different-from-meeting-uid",
          provider_event_id: provider_event_id,
          start_at: DateTime.add(meeting.start_time, -3600, :second),
          end_at: DateTime.add(meeting.end_time, -3600, :second)
        )

      Phoenix.PubSub.subscribe(Tymeslot.PubSub, "calendar_events:#{meeting.organizer_user_id}")

      expect(Tymeslot.CalendarMock, :update_event, fn ^provider_event_id, _data, _ctx -> :ok end)

      assert :ok = CalendarEventSync.update(meeting.id, 1)

      reloaded = Repo.get!(cached.__struct__, cached.id)
      assert DateTime.compare(reloaded.start_at, meeting.start_time) == :eq
      assert DateTime.compare(reloaded.end_at, meeting.end_time) == :eq

      assert_receive {:calendar_events_updated, _user_id, uids}
      assert cached.uid in uids
    end

    test "is a no-op when no cache row exists yet (first outbound push before any inbound sync)" do
      %{meeting: meeting} = setup_calendar_scenario()

      Phoenix.PubSub.subscribe(Tymeslot.PubSub, "calendar_events:#{meeting.organizer_user_id}")

      expect_calendar_update_success()

      assert :ok = CalendarEventSync.update(meeting.id, 1)

      assert {:error, :not_found} =
               ProviderCalendarEventQueries.get_by_uid(
                 meeting.calendar_integration_id,
                 meeting.uid
               )

      refute_receive {:calendar_events_updated, _, _}, 100
    end

    test "does not write through the cache when the outbound push fails" do
      %{integration: integration, meeting: meeting} = setup_calendar_scenario()

      stale_start = DateTime.add(meeting.start_time, -3600, :second)
      stale_end = DateTime.add(meeting.end_time, -3600, :second)

      cached =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          provider: "caldav",
          uid: meeting.uid,
          provider_event_id: nil,
          start_at: stale_start,
          end_at: stale_end
        )

      Phoenix.PubSub.subscribe(Tymeslot.PubSub, "calendar_events:#{meeting.organizer_user_id}")

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _ctx ->
        {:error, :connection_failed}
      end)

      assert {:error, :connection_failed} = CalendarEventSync.update(meeting.id, 1)

      reloaded = Repo.get!(cached.__struct__, cached.id)
      assert DateTime.compare(reloaded.start_at, stale_start) == :eq
      assert DateTime.compare(reloaded.end_at, stale_end) == :eq

      refute_receive {:calendar_events_updated, _, _}, 100
    end
  end

  describe "delete/2" do
    # Deletion is only ever scheduled once the meeting's slot has already
    # been voided (cancellation, or a pending reschedule request) — mirror
    # that here so the guard added below (`expects_calendar_event?/1`)
    # doesn't skip these as stale.
    test "deletes the event" do
      %{meeting: meeting} = setup_calendar_scenario()
      {:ok, meeting} = MeetingQueries.update_meeting(meeting, %{status: "cancelled"})
      uid = meeting.uid

      expect(Tymeslot.CalendarMock, :delete_event, fn ^uid, _ctx -> :ok end)

      assert :ok = CalendarEventSync.delete(meeting.id, 1)
    end

    test "uses provider_event_id when deleting an OAuth event" do
      provider_event_id = "outlook-event-delete"

      %{meeting: meeting} = setup_calendar_scenario(uid: UUID.generate())

      {:ok, meeting} =
        MeetingQueries.update_meeting(meeting, %{
          provider_event_id: provider_event_id,
          status: "cancelled"
        })

      expect(Tymeslot.CalendarMock, :delete_event, fn ^provider_event_id, _ctx -> :ok end)

      assert :ok = CalendarEventSync.delete(meeting.id, 1)
    end

    test "treats a not_found event as success (idempotent)" do
      %{meeting: meeting} = setup_calendar_scenario()
      {:ok, meeting} = MeetingQueries.update_meeting(meeting, %{status: "cancelled"})
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

    test "skips deletion when the meeting has become live again since the job was scheduled" do
      %{meeting: meeting} = setup_calendar_scenario()

      # The reschedule-request flow voids the slot (and schedules this
      # deletion) by setting reschedule_requested_at.
      {:ok, meeting} =
        MeetingQueries.update_meeting(meeting, %{
          reschedule_requested_at: DateTime.utc_now(:second)
        })

      # Before the (possibly retried) job executes, the attendee rebooks —
      # clearing reschedule_requested_at makes the meeting live again.
      {:ok, _meeting} = MeetingQueries.update_meeting(meeting, %{reschedule_requested_at: nil})

      # delete_event must NOT be called — no expectation set, verify_on_exit! enforces it.
      assert :ok = CalendarEventSync.delete(meeting.id, 1)
    end
  end

  describe "provider mapping persistence" do
    test "persists a string-key id map as provider_event_id" do
      %{meeting: meeting} = setup_calendar_scenario(uid: UUID.generate())

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

    test "persists an atom-key id map as provider_event_id" do
      %{meeting: meeting} = setup_calendar_scenario(uid: UUID.generate())

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

    test "persists string-key uid map as provider_event_id and preserves public lookups" do
      %{meeting: meeting} = setup_calendar_scenario(uid: UUID.generate())
      original_uid = meeting.uid

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _ctx ->
        {:ok, %{"uid" => "google-uid-abc"}}
      end)

      expect(Tymeslot.CalendarMock, :get_booking_integration_info, fn _ctx ->
        {:ok, %{integration_id: meeting.calendar_integration_id, calendar_path: "primary"}}
      end)

      assert :ok = CalendarEventSync.create(meeting.id, 1)

      updated = Repo.get!(MeetingSchema, meeting.id)
      assert updated.uid == original_uid
      assert updated.provider_event_id == "google-uid-abc"

      assert {:ok, %{id: meeting_id}} =
               MeetingManagement.validate_and_load_meeting(
                 original_uid,
                 :cancel,
                 meeting.organizer_user_id
               )

      assert meeting_id == meeting.id

      assert {:ok, %{id: ^meeting_id}} =
               Orchestrator.get_meeting_for_reschedule(
                 original_uid,
                 meeting.organizer_user_id
               )
    end

    test "persists atom-key uid map as provider_event_id and supports reconciliation" do
      %{meeting: meeting} = setup_calendar_scenario(uid: UUID.generate())
      original_uid = meeting.uid

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _ctx ->
        {:ok, %{uid: "google-uid-atom"}}
      end)

      expect(Tymeslot.CalendarMock, :get_booking_integration_info, fn _ctx ->
        {:ok, %{integration_id: meeting.calendar_integration_id, calendar_path: "primary"}}
      end)

      assert :ok = CalendarEventSync.create(meeting.id, 1)

      updated = Repo.get!(MeetingSchema, meeting.id)
      assert updated.uid == original_uid
      assert updated.provider_event_id == "google-uid-atom"

      assert {:ok, found} =
               Sync.find_meeting(
                 meeting.calendar_integration_id,
                 "google-uid-atom",
                 "unrelated-ical-uid"
               )

      assert found.id == meeting.id
    end

    test "prefers an explicit id when a provider map also contains uid" do
      %{meeting: meeting} = setup_calendar_scenario(uid: UUID.generate())

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _ctx ->
        {:ok, %{id: "provider-id", uid: "ambiguous-uid"}}
      end)

      expect(Tymeslot.CalendarMock, :get_booking_integration_info, fn _ctx ->
        {:ok, %{integration_id: meeting.calendar_integration_id, calendar_path: "primary"}}
      end)

      assert :ok = CalendarEventSync.create(meeting.id, 1)
      assert Repo.get!(MeetingSchema, meeting.id).provider_event_id == "provider-id"
    end

    test "compensates a map-shaped orphan using the explicit provider id" do
      %{meeting: meeting} = setup_calendar_scenario(uid: UUID.generate())

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _ctx ->
        {:ok, %{id: "exact-provider-id", uid: "ambiguous-uid"}}
      end)

      expect(Tymeslot.CalendarMock, :get_booking_integration_info, fn _ctx ->
        {:ok, %{integration_id: meeting.calendar_integration_id, calendar_path: %{invalid: true}}}
      end)

      expect(Tymeslot.CalendarMock, :delete_event, fn "exact-provider-id", _ctx -> :ok end)

      assert {:error, :calendar_mapping_persistence_failed} =
               CalendarEventSync.create(meeting.id, 1)
    end

    test "surfaces {:error, _} and compensates by deleting the orphaned event when mapping persistence fails" do
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

      # The provider event was created but the mapping write collides on the
      # UID unique constraint. The orphaned provider event must be deleted so a
      # retry of `create` doesn't produce a duplicate.
      expect(Tymeslot.CalendarMock, :delete_event, fn ^external_uid, _ctx -> :ok end)

      assert {:error, :calendar_mapping_persistence_failed} =
               CalendarEventSync.create(meeting.id, 1)

      unchanged = Repo.get!(MeetingSchema, meeting.id)
      assert unchanged.uid == original_uid
    end

    test "tolerates a failed compensation delete and still surfaces the persistence error" do
      %{integration: integration, meeting: meeting} = setup_calendar_scenario_with_paths()
      external_uid = "collides-#{System.unique_integer([:positive])}"

      colliding_start = DateTime.add(meeting.start_time, 1, :hour)

      insert(:meeting,
        uid: external_uid,
        calendar_integration_id: integration.id,
        organizer_user_id: meeting.organizer_user_id,
        start_time: colliding_start,
        end_time: DateTime.add(colliding_start, 60, :minute)
      )

      expect_calendar_create_success(integration.id, external_uid)

      # Even if the compensating delete itself errors, the persistence error is
      # still surfaced for retry (best-effort compensation must not mask it).
      expect(Tymeslot.CalendarMock, :delete_event, fn ^external_uid, _ctx ->
        {:error, :connection_failed}
      end)

      assert {:error, :calendar_mapping_persistence_failed} =
               CalendarEventSync.create(meeting.id, 1)
    end
  end
end
