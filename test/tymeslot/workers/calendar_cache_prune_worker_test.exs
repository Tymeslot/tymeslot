defmodule Tymeslot.Workers.CalendarCachePruneWorkerTest do
  use Tymeslot.DataCase, async: true

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Workers.CalendarCachePruneWorker

  describe "perform/1" do
    test "prunes events that ended more than 90 days ago" do
      integration = insert(:calendar_integration, is_active: true)

      old_event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          start_at: ~U[2025-11-01 10:00:00Z],
          end_at: ~U[2025-11-01 11:00:00Z]
        )

      recent_event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          start_at: DateTime.add(DateTime.utc_now(), -30, :day),
          end_at: DateTime.add(DateTime.utc_now(), -29, :day)
        )

      assert :ok = CalendarCachePruneWorker.perform(%Oban.Job{})

      remaining =
        ProviderCalendarEventQueries.list_for_range(
          [integration.id],
          ~U[2020-01-01 00:00:00Z],
          ~U[2030-01-01 00:00:00Z]
        )

      remaining_ids = Enum.map(remaining, & &1.id)
      refute old_event.id in remaining_ids
      assert recent_event.id in remaining_ids
    end

    test "prunes events from inactive integrations" do
      active = insert(:calendar_integration, is_active: true)
      inactive = insert(:calendar_integration, is_active: false)

      active_event =
        insert(:provider_calendar_event,
          calendar_integration: active,
          start_at: DateTime.add(DateTime.utc_now(), 1, :day),
          end_at: DateTime.add(DateTime.utc_now(), 2, :day)
        )

      _inactive_event =
        insert(:provider_calendar_event,
          calendar_integration: inactive,
          start_at: DateTime.add(DateTime.utc_now(), 1, :day),
          end_at: DateTime.add(DateTime.utc_now(), 2, :day)
        )

      assert :ok = CalendarCachePruneWorker.perform(%Oban.Job{})

      remaining =
        ProviderCalendarEventQueries.list_for_range(
          [active.id, inactive.id],
          ~U[2020-01-01 00:00:00Z],
          ~U[2030-01-01 00:00:00Z]
        )

      assert [found] = remaining
      assert found.id == active_event.id
    end

    test "returns :ok when there is nothing to prune" do
      assert :ok = CalendarCachePruneWorker.perform(%Oban.Job{})
    end
  end
end
