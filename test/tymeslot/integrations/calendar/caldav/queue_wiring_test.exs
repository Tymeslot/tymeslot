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
