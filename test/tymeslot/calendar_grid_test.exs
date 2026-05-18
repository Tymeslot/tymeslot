defmodule Tymeslot.CalendarGridTest do
  use Tymeslot.DataCase, async: true

  @moduletag :calendar

  use Oban.Testing, repo: Tymeslot.Repo

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Workers.SyncCalDavCalendarWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  describe "get_integration_color_indices/1" do
    test "returns empty map for empty list" do
      assert CalendarGrid.get_integration_color_indices([]) == %{}
    end

    test "assigns index 1 to a single integration" do
      result = CalendarGrid.get_integration_color_indices([%{id: 42}])
      assert result == %{42 => 1}
    end

    test "assigns indices by sorted id, not input order" do
      integrations = [%{id: 30}, %{id: 10}, %{id: 20}]
      result = CalendarGrid.get_integration_color_indices(integrations)

      # id 10 is first when sorted → index 1
      # id 20 is second → index 2
      # id 30 is third → index 3
      assert result == %{10 => 1, 20 => 2, 30 => 3}
    end

    test "rotates indices after palette size (8)" do
      integrations = Enum.map(1..10, &%{id: &1})
      result = CalendarGrid.get_integration_color_indices(integrations)

      # First 8 get indices 1..8, then wrap
      assert result[1] == 1
      assert result[8] == 8
      assert result[9] == 1
      assert result[10] == 2
    end
  end

  describe "list_events_for_range/3" do
    setup do
      integration = insert(:calendar_integration)
      %{integration: integration}
    end

    test "returns events within the time range", %{integration: integration} do
      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          start_at: ~U[2026-03-15 10:00:00Z],
          end_at: ~U[2026-03-15 11:00:00Z]
        )

      result =
        CalendarGrid.list_events_for_range(
          [integration.id],
          ~U[2026-03-15 00:00:00Z],
          ~U[2026-03-16 00:00:00Z]
        )

      assert [found] = result
      assert found.id == event.id
    end

    test "excludes events outside the time range", %{integration: integration} do
      insert(:provider_calendar_event,
        calendar_integration: integration,
        start_at: ~U[2026-03-10 10:00:00Z],
        end_at: ~U[2026-03-10 11:00:00Z]
      )

      result =
        CalendarGrid.list_events_for_range(
          [integration.id],
          ~U[2026-03-15 00:00:00Z],
          ~U[2026-03-16 00:00:00Z]
        )

      assert result == []
    end

    test "excludes events from other integrations", %{integration: integration} do
      other = insert(:calendar_integration)

      insert(:provider_calendar_event,
        calendar_integration: other,
        start_at: ~U[2026-03-15 10:00:00Z],
        end_at: ~U[2026-03-15 11:00:00Z]
      )

      result =
        CalendarGrid.list_events_for_range(
          [integration.id],
          ~U[2026-03-15 00:00:00Z],
          ~U[2026-03-16 00:00:00Z]
        )

      assert result == []
    end

    test "excludes events ending exactly at range start (strict boundary)", %{
      integration: integration
    } do
      insert(:provider_calendar_event,
        calendar_integration: integration,
        start_at: ~U[2026-03-14 23:00:00Z],
        end_at: ~U[2026-03-15 00:00:00Z]
      )

      result =
        CalendarGrid.list_events_for_range(
          [integration.id],
          ~U[2026-03-15 00:00:00Z],
          ~U[2026-03-16 00:00:00Z]
        )

      assert result == []
    end

    test "returns empty list when no events match", %{integration: integration} do
      result =
        CalendarGrid.list_events_for_range(
          [integration.id],
          ~U[2026-03-15 00:00:00Z],
          ~U[2026-03-16 00:00:00Z]
        )

      assert result == []
    end

    test "returns empty list for empty integration IDs" do
      result =
        CalendarGrid.list_events_for_range(
          [],
          ~U[2026-03-15 00:00:00Z],
          ~U[2026-03-16 00:00:00Z]
        )

      assert result == []
    end
  end

  describe "refresh_events/1" do
    test "enqueues SyncGoogleCalendarWorker for google integrations" do
      integration = insert(:calendar_integration, provider: "google")

      {:ok, %{enqueued: 1, skipped: 0, errors: []}} =
        CalendarGrid.refresh_events(integration.user_id)

      assert_enqueued(
        worker: SyncGoogleCalendarWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end

    test "enqueues SyncCalDavCalendarWorker for caldav integrations" do
      integration = insert(:calendar_integration, provider: "caldav")

      {:ok, %{enqueued: 1, skipped: 0, errors: []}} =
        CalendarGrid.refresh_events(integration.user_id)

      assert_enqueued(
        worker: SyncCalDavCalendarWorker,
        args: %{"calendar_integration_id" => integration.id, "force_full_fetch" => true}
      )
    end

    test "enqueues SyncCalDavCalendarWorker for radicale integrations" do
      integration = insert(:calendar_integration, provider: "radicale")

      {:ok, %{enqueued: 1, skipped: 0, errors: []}} =
        CalendarGrid.refresh_events(integration.user_id)

      assert_enqueued(
        worker: SyncCalDavCalendarWorker,
        args: %{"calendar_integration_id" => integration.id, "force_full_fetch" => true}
      )
    end

    test "tracks outlook as skipped, not enqueued (webhook-driven, no job fires)" do
      integration = insert(:calendar_integration, provider: "outlook")

      {:ok, result} = CalendarGrid.refresh_events(integration.user_id)

      assert result.enqueued == 0
      assert result.skipped == 1
      assert result.errors == []
      refute_enqueued(worker: SyncGoogleCalendarWorker)
      refute_enqueued(worker: SyncCalDavCalendarWorker)
    end

    test "counts enqueued and skipped across mixed providers" do
      user = insert(:user)
      insert(:calendar_integration, user: user, provider: "google")
      insert(:calendar_integration, user: user, provider: "caldav")
      insert(:calendar_integration, user: user, provider: "outlook")

      {:ok, result} = CalendarGrid.refresh_events(user.id)

      assert result.enqueued == 2
      assert result.skipped == 1
      assert result.errors == []
    end

    test "returns zeros when user has no active integrations" do
      user = insert(:user)

      assert {:ok, %{enqueued: 0, skipped: 0, errors: []}} =
               CalendarGrid.refresh_events(user.id)
    end

    test "enqueues CalDAV sync job with force_full_fetch: true" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true
        )

      assert {:ok, %{enqueued: 1}} = CalendarGrid.refresh_events(user.id)

      assert_enqueued(
        worker: Tymeslot.Workers.SyncCalDavCalendarWorker,
        args: %{
          "calendar_integration_id" => integration.id,
          "force_full_fetch" => true
        }
      )
    end

    test "enqueues Radicale sync job with force_full_fetch: true" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "radicale",
          is_active: true
        )

      assert {:ok, %{enqueued: 1}} = CalendarGrid.refresh_events(user.id)

      assert_enqueued(
        worker: Tymeslot.Workers.SyncCalDavCalendarWorker,
        args: %{
          "calendar_integration_id" => integration.id,
          "force_full_fetch" => true
        }
      )
    end

    test "Google refresh does NOT include force_full_fetch flag" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          is_active: true
        )

      assert {:ok, %{enqueued: 1}} = CalendarGrid.refresh_events(user.id)

      assert_enqueued(
        worker: Tymeslot.Workers.SyncGoogleCalendarWorker,
        args: %{"calendar_integration_id" => integration.id}
      )

      refute_enqueued(
        worker: Tymeslot.Workers.SyncGoogleCalendarWorker,
        args: %{"force_full_fetch" => true}
      )
    end
  end

  describe "stale_integrations/1" do
    test "returns integrations with nil last_external_sync_at" do
      integration = %{
        id: 1,
        provider: "google",
        caldav_sync_tier: nil,
        last_external_sync_at: nil
      }

      assert [^integration] = CalendarGrid.stale_integrations([integration])
    end

    test "returns webhook provider stale after 30 minutes" do
      stale_time = DateTime.add(DateTime.utc_now(), -31, :minute)

      integration = %{
        id: 1,
        provider: "google",
        caldav_sync_tier: nil,
        last_external_sync_at: stale_time
      }

      assert [^integration] = CalendarGrid.stale_integrations([integration])
    end

    test "excludes webhook provider synced within 30 minutes" do
      recent_time = DateTime.add(DateTime.utc_now(), -10, :minute)

      integration = %{
        id: 1,
        provider: "google",
        caldav_sync_tier: nil,
        last_external_sync_at: recent_time
      }

      assert [] = CalendarGrid.stale_integrations([integration])
    end

    test "uses tier-aware thresholds for CalDAV providers" do
      # Tier 1 (sync-token): 25 min threshold
      fresh_t1 = %{
        id: 1,
        provider: "caldav",
        caldav_sync_tier: 1,
        last_external_sync_at: DateTime.add(DateTime.utc_now(), -20, :minute)
      }

      assert [] = CalendarGrid.stale_integrations([fresh_t1])

      stale_t1 = %{
        id: 2,
        provider: "caldav",
        caldav_sync_tier: 1,
        last_external_sync_at: DateTime.add(DateTime.utc_now(), -30, :minute)
      }

      assert [^stale_t1] = CalendarGrid.stale_integrations([stale_t1])

      # Tier 2 (CTag): 45 min threshold
      fresh_t2 = %{
        id: 3,
        provider: "caldav",
        caldav_sync_tier: 2,
        last_external_sync_at: DateTime.add(DateTime.utc_now(), -40, :minute)
      }

      assert [] = CalendarGrid.stale_integrations([fresh_t2])

      stale_t2 = %{
        id: 4,
        provider: "caldav",
        caldav_sync_tier: 2,
        last_external_sync_at: DateTime.add(DateTime.utc_now(), -50, :minute)
      }

      assert [^stale_t2] = CalendarGrid.stale_integrations([stale_t2])

      # Tier 3 (full fetch): 90 min threshold
      fresh_t3 = %{
        id: 5,
        provider: "caldav",
        caldav_sync_tier: 3,
        last_external_sync_at: DateTime.add(DateTime.utc_now(), -80, :minute)
      }

      assert [] = CalendarGrid.stale_integrations([fresh_t3])

      stale_t3 = %{
        id: 6,
        provider: "caldav",
        caldav_sync_tier: 3,
        last_external_sync_at: DateTime.add(DateTime.utc_now(), -100, :minute)
      }

      assert [^stale_t3] = CalendarGrid.stale_integrations([stale_t3])
    end

    test "uses default threshold for CalDAV with nil tier" do
      # nil tier uses 25 min default (same as Tier 1)
      fresh = %{
        id: 1,
        provider: "caldav",
        caldav_sync_tier: nil,
        last_external_sync_at: DateTime.add(DateTime.utc_now(), -20, :minute)
      }

      assert [] = CalendarGrid.stale_integrations([fresh])

      stale = %{
        id: 2,
        provider: "caldav",
        caldav_sync_tier: nil,
        last_external_sync_at: DateTime.add(DateTime.utc_now(), -30, :minute)
      }

      assert [^stale] = CalendarGrid.stale_integrations([stale])
    end

    test "applies CalDAV thresholds to all CalDAV-based providers" do
      recent = DateTime.add(DateTime.utc_now(), -10, :minute)

      for provider <- ~w(caldav radicale nextcloud zimbra) do
        integration = %{
          id: 1,
          provider: provider,
          caldav_sync_tier: 1,
          last_external_sync_at: recent
        }

        assert [] = CalendarGrid.stale_integrations([integration])
      end
    end

    test "returns empty list when all integrations are fresh" do
      recent = DateTime.add(DateTime.utc_now(), -5, :minute)

      integrations = [
        %{id: 1, provider: "google", caldav_sync_tier: nil, last_external_sync_at: recent},
        %{id: 2, provider: "outlook", caldav_sync_tier: nil, last_external_sync_at: recent}
      ]

      assert [] = CalendarGrid.stale_integrations(integrations)
    end

    test "excludes Outlook pending initial setup from stale" do
      # Outlook with no delta link and no sync: pending setup, not stale
      pending = %{
        id: 1,
        provider: "outlook",
        caldav_sync_tier: nil,
        graph_delta_link: nil,
        last_external_sync_at: nil
      }

      assert [] = CalendarGrid.stale_integrations([pending])
    end

    test "includes Outlook with delta link but nil sync as stale" do
      # Has a delta link but no sync timestamp: something is wrong
      broken = %{
        id: 1,
        provider: "outlook",
        caldav_sync_tier: nil,
        graph_delta_link: "https://graph.microsoft.com/v1.0/me/events/delta?token=abc",
        last_external_sync_at: nil
      }

      assert [^broken] = CalendarGrid.stale_integrations([broken])
    end

    test "filters mixed fresh and stale integrations" do
      recent = DateTime.add(DateTime.utc_now(), -5, :minute)
      stale_time = DateTime.add(DateTime.utc_now(), -60, :minute)

      fresh = %{id: 1, provider: "google", caldav_sync_tier: nil, last_external_sync_at: recent}

      stale = %{
        id: 2,
        provider: "outlook",
        caldav_sync_tier: nil,
        last_external_sync_at: stale_time
      }

      assert [^stale] = CalendarGrid.stale_integrations([fresh, stale])
    end
  end

  describe "oldest_sync_at/1" do
    test "returns nil for empty list" do
      assert CalendarGrid.oldest_sync_at([]) == nil
    end

    test "returns nil when all integrations have nil sync times" do
      integrations = [
        %{last_external_sync_at: nil},
        %{last_external_sync_at: nil}
      ]

      assert CalendarGrid.oldest_sync_at(integrations) == nil
    end

    test "returns the earliest timestamp" do
      old = ~U[2026-03-18 08:00:00Z]
      recent = ~U[2026-03-18 12:00:00Z]

      integrations = [
        %{last_external_sync_at: recent},
        %{last_external_sync_at: old}
      ]

      assert CalendarGrid.oldest_sync_at(integrations) == old
    end

    test "ignores nil values and returns earliest non-nil" do
      timestamp = ~U[2026-03-18 10:00:00Z]

      integrations = [
        %{last_external_sync_at: nil},
        %{last_external_sync_at: timestamp}
      ]

      assert CalendarGrid.oldest_sync_at(integrations) == timestamp
    end
  end

  describe "cache_created_event/1" do
    test "accepts second-precision DateTimes from the dashboard create flow" do
      # Regression: the in-dashboard create handler builds start_at/end_at via
      # DateTime.new!/Time.new!, which yields second precision. The cached events
      # schema uses :utc_datetime_usec, so the cache path must upcast or tolerate
      # the lower precision instead of crashing in insert_all.
      integration = insert(:calendar_integration)

      start_at = DateTime.new!(~D[2026-04-14], ~T[15:45:00], "Etc/UTC")
      end_at = DateTime.new!(~D[2026-04-14], ~T[16:15:00], "Etc/UTC")

      assert :ok =
               CalendarGrid.cache_created_event(%{
                 uid: "regression-second-precision",
                 calendar_integration_id: integration.id,
                 provider: "nextcloud",
                 provider_calendar_id: "primary",
                 summary: "Test",
                 start_at: start_at,
                 end_at: end_at,
                 all_day: false
               })

      assert {:ok, cached} =
               CalendarGrid.get_cached_event(integration.id, "regression-second-precision")

      assert cached.summary == "Test"
    end
  end

  describe "update_cached_event/1" do
    test "accepts second-precision synced_at from the dashboard update flow" do
      # Regression: EditWorkflow.Updates.update_event_async / update_attendees_async /
      # update_field_async previously built cache rows with
      # DateTime.utc_now(:second). synced_at is :utc_datetime_usec, so the cache
      # path must upcast lower precision instead of crashing the async task in
      # Repo.insert_all.
      integration = insert(:calendar_integration)

      insert(:provider_calendar_event,
        uid: "regression-update-second-precision",
        calendar_integration: integration,
        summary: "Before"
      )

      start_at = DateTime.new!(~D[2026-04-14], ~T[15:45:00], "Etc/UTC")
      end_at = DateTime.new!(~D[2026-04-14], ~T[16:15:00], "Etc/UTC")

      assert :ok =
               CalendarGrid.update_cached_event(%{
                 uid: "regression-update-second-precision",
                 calendar_integration_id: integration.id,
                 provider: "nextcloud",
                 provider_calendar_id: "primary",
                 summary: "After",
                 start_at: start_at,
                 end_at: end_at,
                 all_day: false,
                 synced_at: DateTime.utc_now(:second)
               })

      assert {:ok, cached} =
               CalendarGrid.get_cached_event(integration.id, "regression-update-second-precision")

      assert cached.summary == "After"
    end
  end
end
