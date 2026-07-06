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

    # Deliberately no rollback-path test at this boundary. The original test
    # asserted that duplicate uids in one batch triggered Postgres's
    # "ON CONFLICT DO UPDATE cannot affect row a second time" error, which
    # `upsert_cache` would rescue into `{:error, _}` and `Repo.rollback`
    # would observe. That trigger became obsolete once `upsert_batch`
    # started deduping by `{calendar_integration_id, uid}` to cope with
    # Google's duplicate-recurring-instance responses — the insert now
    # silently collapses to a single row and succeeds, so there is no
    # error for the transaction to roll back.
    #
    # The dedup behaviour that invalidated this trigger is pinned by
    # `provider_calendar_event_queries_test.exs` ("deduplicates entries
    # with the same uid within a single batch"). The rollback wrapping
    # itself is a straight `Repo.transaction(fn -> … Repo.rollback(_) end)`
    # in `SyncReconciler.run_atomic_full_fetch/6` — changing it would
    # require a new error trigger, at which point this suite is the right
    # place to regain rollback coverage.
  end

  describe "process_full_fetch/6 deletion circuit breaker" do
    @start_time ~U[2026-04-01 00:00:00Z]
    @end_time ~U[2026-04-30 00:00:00Z]
    @sync_started_at ~U[2026-04-15 12:00:00.000000Z]

    defp seed_cached_event(integration, uid) do
      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: uid,
        provider: "caldav",
        provider_calendar_id: "/cal/",
        provider_event_id: "/cal/#{uid}.ics",
        start_at: ~U[2026-04-15 10:00:00.000000Z],
        end_at: ~U[2026-04-15 11:00:00.000000Z],
        synced_at: ~U[2026-04-15 00:00:00.000000Z]
      )
    end

    defp raw_event(uid) do
      %{
        uid: uid,
        summary: "Event #{uid}",
        provider_event_id: "/cal/#{uid}.ics",
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
        etag: "\"e-#{uid}\"",
        raw_ical:
          "BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VEVENT\nUID:#{uid}\nEND:VEVENT\nEND:VCALENDAR\n"
      }
    end

    test "refuses deletions and rolls back on an empty listing over a populated cache",
         %{integration: integration} do
      for i <- 1..3, do: seed_cached_event(integration, "cached-#{i}")

      # A syntactically valid but empty response must never be read as "every
      # event was deleted" — that would auto-cancel every linked meeting.
      assert {:error, :suspicious_bulk_deletion} =
               SyncReconciler.process_full_fetch(
                 integration,
                 [],
                 @start_time,
                 @end_time,
                 @sync_started_at,
                 "/cal/"
               )

      for i <- 1..3 do
        assert {:ok, _event} =
                 ProviderCalendarEventQueries.get_by_uid(integration.id, "cached-#{i}")
      end
    end

    test "refuses deletions when most of a non-trivial cache would be removed",
         %{integration: integration} do
      for i <- 1..6, do: seed_cached_event(integration, "cached-#{i}")

      # Server returns only 1 of the 6 cached events → 5/6 (83%) would vanish.
      assert {:error, :suspicious_bulk_deletion} =
               SyncReconciler.process_full_fetch(
                 integration,
                 [raw_event("cached-1")],
                 @start_time,
                 @end_time,
                 @sync_started_at,
                 "/cal/"
               )

      for i <- 1..6 do
        assert {:ok, _event} =
                 ProviderCalendarEventQueries.get_by_uid(integration.id, "cached-#{i}")
      end
    end

    test "still reconciles an ordinary minority of missing events",
         %{integration: integration} do
      for i <- 1..6, do: seed_cached_event(integration, "cached-#{i}")

      # Server returns 4 of 6 cached → 2/6 (33%) missing, below the threshold.
      fetched = Enum.map(1..4, &raw_event("cached-#{&1}"))

      assert :ok =
               SyncReconciler.process_full_fetch(
                 integration,
                 fetched,
                 @start_time,
                 @end_time,
                 @sync_started_at,
                 "/cal/"
               )

      assert {:error, :not_found} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "cached-5")

      assert {:error, :not_found} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "cached-6")

      assert {:ok, _event} = ProviderCalendarEventQueries.get_by_uid(integration.id, "cached-1")
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
