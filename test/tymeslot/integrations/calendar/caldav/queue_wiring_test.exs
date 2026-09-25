defmodule Tymeslot.Integrations.Calendar.CalDAV.QueueWiringTest do
  @moduledoc """
  Verifies that `QueueWiring.tag/3` and `clear/2` write the correct
  `sync_state` to `provider_calendar_events` when a failing CalDAV write
  needs to be replayed by `OfflineQueue` on the next sync cycle.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.CalDAV.QueueWiring
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

  defp caldav_integration do
    insert(:calendar_integration,
      provider: "caldav",
      calendar_paths: ["/cal/"]
    )
  end

  defp google_integration do
    insert(:calendar_integration, provider: "google", calendar_paths: [])
  end

  defp build_meeting(integration, uid) do
    %{
      uid: uid,
      calendar_integration_id: integration.id
    }
  end

  defp event_data do
    %{
      summary: "Team sync",
      description: "Weekly catch-up",
      location: "Boardroom",
      timezone: "UTC",
      start_time: ~U[2026-05-01 10:00:00Z],
      end_time: ~U[2026-05-01 11:00:00Z]
    }
  end

  describe "tag/3" do
    test "writes locally_created with summary/times for :create" do
      integration = caldav_integration()
      meeting = build_meeting(integration, "new-uid")

      assert :ok = QueueWiring.tag(meeting, :create, event_data())

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, "new-uid")
      assert row.sync_state == "locally_created"
      assert row.summary == "Team sync"
      assert row.location == "Boardroom"
      assert row.start_at == ~U[2026-05-01 10:00:00.000000Z]
      assert row.end_at == ~U[2026-05-01 11:00:00.000000Z]
      assert row.created_by_tymeslot == true
    end

    test "writes locally_modified for :update" do
      integration = caldav_integration()
      meeting = build_meeting(integration, "existing-uid")

      assert :ok = QueueWiring.tag(meeting, :update, event_data())

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, "existing-uid")
      assert row.sync_state == "locally_modified"
    end

    test "writes locally_deleted for :delete" do
      integration = caldav_integration()
      meeting = build_meeting(integration, "to-delete")

      assert :ok = QueueWiring.tag(meeting, :delete, event_data())

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, "to-delete")
      assert row.sync_state == "locally_deleted"
    end

    test "is idempotent — second tag overwrites the first with the latest action" do
      integration = caldav_integration()
      meeting = build_meeting(integration, "evolving-uid")

      assert :ok = QueueWiring.tag(meeting, :create, event_data())
      assert :ok = QueueWiring.tag(meeting, :update, event_data())

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, "evolving-uid")
      assert row.sync_state == "locally_modified"
    end

    test "returns :ignored for non-CalDAV providers" do
      integration = google_integration()
      meeting = build_meeting(integration, "google-uid")

      assert :ignored = QueueWiring.tag(meeting, :create, event_data())

      # No cache row was written.
      assert {:error, :not_found} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "google-uid")
    end

    test "returns :ignored when meeting has no calendar_integration_id" do
      meeting = %{uid: "orphan", calendar_integration_id: nil}

      assert :ignored = QueueWiring.tag(meeting, :create, event_data())
    end

    test "returns :ignored when the integration does not exist" do
      meeting = %{uid: "ghost", calendar_integration_id: 999_999}

      assert :ignored = QueueWiring.tag(meeting, :create, event_data())
    end

    # Regression tests for the CalDAV nil-paths crash fixed by
    # c9b8265af, e0f6b212d and ccdb25cf6. A CalDAV integration whose
    # calendar_paths column is empty (new/unbootstrapped) or nil (old
    # records before the non-null default) must fall through to
    # `:ignored` rather than raising on a NOT NULL violation.
    test "returns :ignored when a CalDAV integration has an empty calendar_paths" do
      integration = insert(:calendar_integration, provider: "caldav", calendar_paths: [])
      meeting = build_meeting(integration, "empty-paths")

      assert :ignored = QueueWiring.tag(meeting, :create, event_data())

      assert {:error, :not_found} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "empty-paths")
    end

    test "returns :ignored when a CalDAV integration has nil calendar_paths" do
      integration = insert(:calendar_integration, provider: "caldav", calendar_paths: nil)
      meeting = build_meeting(integration, "nil-paths")

      assert :ignored = QueueWiring.tag(meeting, :create, event_data())

      assert {:error, :not_found} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "nil-paths")
    end

    # Regression: a booking still awaiting the host's approval must stay
    # tentative through an offline-queue round trip. `event_data[:status]`
    # is exactly what `CalendarEventBuilder.build_event_data/1` sets, so a
    # cache row losing it means the eventual replay writes the held request
    # to the host's calendar as an ordinary confirmed event.
    test "carries the tentative status through from event_data for a held request" do
      integration = caldav_integration()
      meeting = build_meeting(integration, "gated-uid")
      data = Map.merge(event_data(), %{status: :tentative, transparency: :opaque})

      assert :ok = QueueWiring.tag(meeting, :create, data)

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, "gated-uid")
      assert row.status == "tentative"
      assert row.transparency == "opaque"
    end

    test "defaults to confirmed/opaque when event_data carries no status (e.g. a delete)" do
      integration = caldav_integration()
      meeting = build_meeting(integration, "no-status-uid")

      assert :ok = QueueWiring.tag(meeting, :delete, event_data())

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, "no-status-uid")
      assert row.status == "confirmed"
      assert row.transparency == "opaque"
    end
  end

  describe "tag/3 — what a partial write must leave alone" do
    # `{:replace, …}` on an upsert replaces with EXCLUDED, which for a column
    # the insert omits is NULL. The queue tag used to name every content
    # column in that list while supplying a third of them, so tagging an event
    # destroyed the identity and content of the row it was about to replay.
    test "a queued delete keeps the cached row's identity and content" do
      integration = caldav_integration()

      row =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          uid: "keeps-identity",
          provider: "caldav",
          provider_calendar_id: "/cal/other/",
          provider_event_id: "/cal/other/keeps-identity.ics",
          etag: "\"server-etag\"",
          raw_ical: "BEGIN:VCALENDAR\r\nEND:VCALENDAR",
          summary: "Standup",
          recurrence_rule: "FREQ=WEEKLY;BYDAY=MO",
          attendees: [%{"email" => "sam@example.com"}],
          reminders: [%{"minutes_before" => 10}],
          start_at: ~U[2026-05-01 10:00:00.000000Z],
          end_at: ~U[2026-05-01 11:00:00.000000Z],
          synced_at: ~U[2026-05-01 00:00:00.000000Z]
        )

      assert :ok =
               QueueWiring.tag(build_meeting(integration, "keeps-identity"), :delete, %{})

      {:ok, reloaded} = ProviderCalendarEventQueries.get_by_uid(integration.id, "keeps-identity")

      assert reloaded.sync_state == "locally_deleted"

      assert reloaded.provider_event_id == row.provider_event_id
      assert reloaded.etag == row.etag
      assert reloaded.raw_ical == row.raw_ical
      assert reloaded.provider_calendar_id == row.provider_calendar_id
      assert reloaded.summary == row.summary
      assert reloaded.recurrence_rule == row.recurrence_rule
      assert reloaded.attendees == row.attendees
      assert reloaded.reminders == row.reminders
      assert reloaded.start_at == row.start_at
      assert reloaded.end_at == row.end_at
    end

    test "an update writes the fields it carries and keeps the ones it does not" do
      integration = caldav_integration()

      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "partial-update",
        provider: "caldav",
        provider_event_id: "/cal/partial-update.ics",
        etag: "\"server-etag\"",
        summary: "Old title",
        attendees: [%{"email" => "sam@example.com"}],
        start_at: ~U[2026-05-01 10:00:00.000000Z],
        end_at: ~U[2026-05-01 11:00:00.000000Z],
        synced_at: ~U[2026-05-01 00:00:00.000000Z]
      )

      assert :ok =
               QueueWiring.tag(build_meeting(integration, "partial-update"), :update, %{
                 summary: "New title"
               })

      {:ok, reloaded} = ProviderCalendarEventQueries.get_by_uid(integration.id, "partial-update")

      assert reloaded.summary == "New title"
      assert reloaded.attendees == [%{"email" => "sam@example.com"}]
      assert reloaded.provider_event_id == "/cal/partial-update.ics"
      assert reloaded.etag == "\"server-etag\""
    end
  end

  describe "tag/3 — timing shapes" do
    # `resolve_timing/1` only understood `%DateTime{}`, so an all-day edit or a
    # payload that had been through JSON wrote no timing at all and
    # `OfflineQueue.sendable_event_data/1` then refused the row forever.
    test "an all-day change is stored as dates, not as null timestamps" do
      integration = caldav_integration()

      assert :ok =
               QueueWiring.tag(build_meeting(integration, "all-day"), :update, %{
                 summary: "Offsite",
                 start_time: ~D[2026-05-01],
                 end_time: ~D[2026-05-02]
               })

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, "all-day")

      assert row.all_day == true
      assert row.start_date == ~D[2026-05-01]
      assert row.end_date == ~D[2026-05-02]
      assert row.start_at == nil
      assert row.end_at == nil
    end

    test "ISO-8601 strings from a JSON round-trip are stored as timestamps" do
      integration = caldav_integration()

      assert :ok =
               QueueWiring.tag(build_meeting(integration, "from-json"), :update, %{
                 "summary" => "Round-tripped",
                 "start_time" => "2026-05-01T10:00:00Z",
                 "end_time" => "2026-05-01T11:00:00Z"
               })

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, "from-json")

      assert row.all_day == false
      assert row.start_at == ~U[2026-05-01 10:00:00.000000Z]
      assert row.end_at == ~U[2026-05-01 11:00:00.000000Z]
      assert row.summary == "Round-tripped"
    end
  end

  describe "clear/2" do
    test "flips a tagged row back to synced and persists etag" do
      integration = caldav_integration()
      meeting = build_meeting(integration, "round-trip-uid")

      assert :ok = QueueWiring.tag(meeting, :update, event_data())
      assert :ok = QueueWiring.clear(meeting, "\"server-etag\"")

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, "round-trip-uid")
      assert row.sync_state == "synced"
      assert row.sync_attempts == 0
      assert row.etag == "\"server-etag\""
    end

    test "is a no-op when no cache row exists" do
      integration = caldav_integration()
      meeting = build_meeting(integration, "never-tagged")

      assert :ok = QueueWiring.clear(meeting, nil)

      assert {:error, :not_found} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "never-tagged")
    end
  end
end
