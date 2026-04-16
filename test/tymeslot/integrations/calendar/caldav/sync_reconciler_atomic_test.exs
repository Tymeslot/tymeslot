defmodule Tymeslot.Integrations.Calendar.CalDAV.SyncReconcilerAtomicTest do
  @moduledoc """
  Atomicity tests for `SyncReconciler.process_full_fetch/6` and
  `process_tier1/3`.

  Proves that cache upserts and deletions commit together, and that a
  failure during the delete step rolls the whole batch back so the cache
  never observes a partial sync.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.CalDAV.SyncReconciler
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo

  setup do
    integration =
      insert(:calendar_integration,
        provider: "caldav",
        calendar_paths: ["/cal/"]
      )

    {:ok, integration: integration}
  end

  describe "process_full_fetch/6" do
    test "commits upserts and deletions together", %{integration: integration} do
      # Seed a stale event that should be deleted by the sync
      stale =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          uid: "stale-uid",
          provider: "caldav",
          provider_calendar_id: "/cal/",
          provider_event_id: "/cal/stale-uid.ics",
          start_at: ~U[2026-04-15 10:00:00.000000Z],
          end_at: ~U[2026-04-15 11:00:00.000000Z],
          synced_at: ~U[2026-04-15 00:00:00.000000Z]
        )

      raw_ical_body = """
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:fresh-uid
      SUMMARY:Fresh event
      END:VEVENT
      END:VCALENDAR
      """

      # Server response contains one new event; "stale-uid" is absent and
      # should be deleted.
      raw_events = [
        %{
          uid: "fresh-uid",
          summary: "Fresh event",
          provider_event_id: "/cal/fresh-uid.ics",
          start_time: ~U[2026-04-15 14:00:00Z],
          end_time: ~U[2026-04-15 15:00:00Z],
          description: nil,
          location: nil,
          all_day: false,
          timezone: "UTC",
          status: "confirmed",
          transparency: "opaque",
          attendees: [],
          organiser: nil,
          recurrence_rule: nil,
          recurrence_exceptions: [],
          etag: "\"fresh-etag\"",
          raw_ical: raw_ical_body
        }
      ]

      start_time = ~U[2026-04-01 00:00:00Z]
      end_time = ~U[2026-04-30 00:00:00Z]
      sync_started_at = ~U[2026-04-15 12:00:00.000000Z]

      assert :ok =
               SyncReconciler.process_full_fetch(
                 integration,
                 raw_events,
                 start_time,
                 end_time,
                 sync_started_at,
                 "/cal/"
               )

      # The stale event is gone and the fresh one is present.
      assert {:error, :not_found} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "stale-uid")

      assert {:ok, %ProviderCalendarEventSchema{summary: "Fresh event", raw_ical: persisted}} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "fresh-uid")

      assert persisted == raw_ical_body

      # The original row has really been deleted, not just shadowed.
      refute Repo.reload(stale)
    end

    test "rolls back the entire transaction when the upsert batch fails",
         %{integration: integration} do
      _stale =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          uid: "stale-uid",
          provider: "caldav",
          provider_calendar_id: "/cal/",
          provider_event_id: "/cal/stale-uid.ics",
          start_at: ~U[2026-04-15 10:00:00.000000Z],
          end_at: ~U[2026-04-15 11:00:00.000000Z],
          synced_at: ~U[2026-04-15 00:00:00.000000Z]
        )

      # Passing two events with the same uid in a single batch causes Postgres to
      # raise "ON CONFLICT DO UPDATE command cannot affect row a second time",
      # which upsert_cache rescues and returns as {:error, reason}, triggering
      # Repo.rollback inside the transaction and rolling the whole batch back.
      raw_events = [
        %{
          uid: "fresh-uid",
          summary: "Fresh event",
          provider_event_id: "/cal/fresh-uid.ics",
          start_time: ~U[2026-04-15 14:00:00Z],
          end_time: ~U[2026-04-15 15:00:00Z],
          description: nil,
          location: nil,
          all_day: false,
          timezone: "UTC",
          status: "confirmed",
          transparency: "opaque",
          attendees: [],
          organiser: nil,
          recurrence_rule: nil,
          recurrence_exceptions: [],
          etag: "\"fresh-etag\""
        },
        %{
          uid: "fresh-uid",
          summary: "Duplicate of Fresh event",
          provider_event_id: "/cal/fresh-uid-dup.ics",
          start_time: ~U[2026-04-15 14:00:00Z],
          end_time: ~U[2026-04-15 15:00:00Z],
          description: nil,
          location: nil,
          all_day: false,
          timezone: "UTC",
          status: "confirmed",
          transparency: "opaque",
          attendees: [],
          organiser: nil,
          recurrence_rule: nil,
          recurrence_exceptions: [],
          etag: "\"fresh-etag-dup\""
        }
      ]

      assert {:error, _reason} =
               SyncReconciler.process_full_fetch(
                 integration,
                 raw_events,
                 ~U[2026-04-01 00:00:00Z],
                 ~U[2026-04-30 00:00:00Z],
                 ~U[2026-04-15 12:00:00.000000Z],
                 "/cal/"
               )

      # Neither the upsert nor the delete took effect:
      # * fresh-uid is NOT present (upsert was rolled back)
      # * stale-uid IS still present (delete step was never reached)
      assert {:error, :not_found} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "fresh-uid")

      assert {:ok, %ProviderCalendarEventSchema{uid: "stale-uid"}} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "stale-uid")
    end
  end

  describe "process_tier1/3" do
    test "commits upserts and href-based deletions together",
         %{integration: integration} do
      _stale =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          uid: "deleted-uid",
          provider: "caldav",
          provider_calendar_id: "/cal/",
          provider_event_id: "/cal/deleted.ics",
          start_at: ~U[2026-04-15 10:00:00.000000Z],
          end_at: ~U[2026-04-15 11:00:00.000000Z],
          synced_at: ~U[2026-04-15 00:00:00.000000Z]
        )

      raw_events = [
        %{
          uid: "fresh-uid",
          summary: "Fresh event",
          provider_event_id: "/cal/fresh-uid.ics",
          start_time: ~U[2026-04-15 14:00:00Z],
          end_time: ~U[2026-04-15 15:00:00Z],
          description: nil,
          location: nil,
          all_day: false,
          timezone: "UTC",
          status: "confirmed",
          transparency: "opaque",
          attendees: [],
          organiser: nil,
          recurrence_rule: nil,
          recurrence_exceptions: [],
          etag: "\"fresh-etag\""
        }
      ]

      deleted_hrefs = ["/cal/deleted.ics"]

      assert :ok = SyncReconciler.process_tier1(integration, raw_events, deleted_hrefs)

      assert {:error, :not_found} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "deleted-uid")

      assert {:ok, %ProviderCalendarEventSchema{summary: "Fresh event"}} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "fresh-uid")
    end
  end
end
