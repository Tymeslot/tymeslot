defmodule Tymeslot.Meetings.CalendarEventSyncCacheTest do
  @moduledoc """
  The outbound write-through: what `CalendarEventSync.update/2` does to the
  local `provider_calendar_events` cache row once the provider push has landed.

  Its own module rather than another describe block in
  `CalendarEventSyncTest`, because it is the only part of the sync flow that
  asserts on the cache table rather than on the provider call, and the two
  together push that file past the module-size limit.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :meetings
  @moduletag :calendar
  @moduletag :integration

  import Mox
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers

  alias Ecto.UUID
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Meetings.CalendarEventSync
  alias Tymeslot.Meetings.MeetingQueries

  setup :verify_on_exit!

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

      reloaded = Repo.get!(ProviderCalendarEventSchema, cached.id)
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

      reloaded = Repo.get!(ProviderCalendarEventSchema, cached.id)
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

      reloaded = Repo.get!(ProviderCalendarEventSchema, cached.id)
      assert DateTime.compare(reloaded.start_at, stale_start) == :eq
      assert DateTime.compare(reloaded.end_at, stale_end) == :eq

      refute_receive {:calendar_events_updated, _, _}, 100
    end
  end

  describe "update/2 cache write-through (linkage, field selection, invalidation)" do
    test "falls back to uid when the meeting's provider_event_id matches no cache row" do
      # `CalendarEventLink`'s rule — and the grid dedup's — is that the two
      # sides match on *any* shared identifier, so a row reachable only by uid
      # is linked even though the meeting also carries a provider event id.
      # Keying the lookup on provider_event_id alone left it stale.
      %{integration: integration, meeting: meeting} = setup_calendar_scenario()

      {:ok, meeting} =
        MeetingQueries.update_meeting(meeting, %{provider_event_id: "id-no-cache-row-carries"})

      stale_start = DateTime.add(meeting.start_time, -3600, :second)

      cached =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          provider: "caldav",
          uid: meeting.uid,
          provider_event_id: "caldav-href-unrelated-to-the-meeting",
          start_at: stale_start,
          end_at: DateTime.add(meeting.end_time, -3600, :second)
        )

      expect(Tymeslot.CalendarMock, :update_event, fn _id, _data, _ctx -> :ok end)

      assert :ok = CalendarEventSync.update(meeting.id, 1)

      reloaded = Repo.get!(ProviderCalendarEventSchema, cached.id)
      assert DateTime.compare(reloaded.start_at, meeting.start_time) == :eq
    end

    test "writes the pushed status through, so approval's TENTATIVE flip reaches the cache" do
      %{integration: integration, meeting: meeting} = setup_calendar_scenario()

      cached =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          provider: "caldav",
          uid: meeting.uid,
          provider_event_id: nil,
          status: "tentative"
        )

      expect_calendar_update_success()

      assert :ok = CalendarEventSync.update(meeting.id, 1)

      # The factory's meeting is confirmed, so the builder pushes CONFIRMED.
      assert Repo.get!(ProviderCalendarEventSchema, cached.id).status == "confirmed"
    end

    test "writes the pushed transparency through for a show_as_free meeting" do
      %{integration: integration, meeting: meeting} = setup_calendar_scenario()

      {:ok, meeting} = MeetingQueries.update_meeting(meeting, %{show_as_free: true})

      cached =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          provider: "caldav",
          uid: meeting.uid,
          provider_event_id: nil,
          transparency: "opaque"
        )

      expect_calendar_update_success()

      assert :ok = CalendarEventSync.update(meeting.id, 1)

      assert Repo.get!(ProviderCalendarEventSchema, cached.id).transparency == "transparent"
    end

    test "leaves timezone alone — the push carries the booker's zone, not the event's TZID" do
      %{integration: integration, meeting: meeting} = setup_calendar_scenario()

      # The factory meeting's attendee_timezone is America/New_York; a CalDAV
      # row legitimately carries no TZID at all, and must not acquire one here.
      assert meeting.attendee_timezone == "America/New_York"

      cached =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          provider: "caldav",
          uid: meeting.uid,
          provider_event_id: nil,
          timezone: nil
        )

      expect_calendar_update_success()

      assert :ok = CalendarEventSync.update(meeting.id, 1)

      assert Repo.get!(ProviderCalendarEventSchema, cached.id).timezone == nil
    end

    test "invalidates the host's cached availability, which Exchange answers from this table" do
      %{integration: integration, meeting: meeting} = setup_calendar_scenario()

      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider: "caldav",
        uid: meeting.uid,
        provider_event_id: nil
      )

      key = AvailabilityCache.booking_window_events_key(meeting.organizer_user_id)

      assert {:ok, :before} =
               AvailabilityCache.get_or_compute_events(key, fn -> {:ok, :before} end)

      assert {:ok, :before} =
               AvailabilityCache.get_or_compute_events(key, fn -> {:ok, :after} end)

      expect_calendar_update_success()

      assert :ok = CalendarEventSync.update(meeting.id, 1)

      assert {:ok, :after} = AvailabilityCache.get_or_compute_events(key, fn -> {:ok, :after} end)
    end
  end
end
