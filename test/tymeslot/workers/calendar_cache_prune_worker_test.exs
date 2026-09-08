defmodule Tymeslot.Workers.CalendarCachePruneWorkerTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Workers.CalendarCachePruneWorker

  describe "perform/1" do
    test "keeps what the next sync will re-fetch and prunes what it can no longer reach" do
      integration = insert(:calendar_integration, is_active: true)
      now = DateTime.utc_now()
      window_days = ProviderConfig.sync_window_past_days()

      # Well inside the window every provider still reads. Pruning this row
      # would delete it only for the next sync to write straight back, which
      # is what a retention shorter than the sync window used to cause.
      refetchable = insert_event_ending(integration, now, window_days - 30)

      # Beyond the window and its grace period: nothing will refresh this row
      # again, so it is dead weight.
      unreachable = insert_event_ending(integration, now, window_days + 90)

      assert :ok = CalendarCachePruneWorker.perform(%Oban.Job{})

      remaining_ids = remaining_event_ids([integration.id])

      assert refetchable.id in remaining_ids
      refute unreachable.id in remaining_ids
    end

    defp insert_event_ending(integration, now, days_ago) do
      ends_at = DateTime.add(now, -days_ago, :day)

      insert(:provider_calendar_event,
        calendar_integration: integration,
        start_at: DateTime.add(ends_at, -1, :hour),
        end_at: ends_at
      )
    end

    defp remaining_event_ids(integration_ids) do
      integration_ids
      |> ProviderCalendarEventQueries.list_for_range(
        ~U[2020-01-01 00:00:00Z],
        ~U[2030-01-01 00:00:00Z]
      )
      |> Enum.map(& &1.id)
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

  describe "uniqueness" do
    test "a second enqueue inside the 24-hour window is coalesced, not duplicated" do
      # The worker declares `unique: [period: 86_400, states: [...]]` so the
      # daily cron can't double-fire. Regressing this would spawn redundant
      # prune passes on every scheduler tick.
      {:ok, first} = Oban.insert(CalendarCachePruneWorker.new(%{}))
      {:ok, second} = Oban.insert(CalendarCachePruneWorker.new(%{}))

      assert second.id == first.id

      assert [_only] =
               all_enqueued(worker: CalendarCachePruneWorker)
    end
  end
end
