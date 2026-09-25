defmodule Tymeslot.Workers.FallbackSyncSweepWorkerGoogleCapTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.HealthCheck.Monitor
  alias Tymeslot.Workers.FallbackSyncSweepWorker
  alias Tymeslot.Workers.IntegrationAutoPauseWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  setup :verify_on_exit!

  describe "perform/1 - google pagination-cap failures eventually stop being swept" do
    # A capped Google sync (`:too_many_pages`) does not raise
    # `consecutive_hard_failures`, so it is invisible to `SyncGating` by
    # design, the same as a CalDAV sync failure. What actually removes a
    # sustained streak of them from the sweep is `IntegrationAutoPauseWorker`
    # deactivating the integration once the streak has held it unhealthy for
    # the prolonged-unhealthy window; the sweep only ever enqueues active
    # integrations. This test drives the real worker through the streak so
    # the health state comes from the code under fix, not from a hand-built
    # fixture, and only backdates `became_unhealthy_at` to stand in for the
    # elapsed days a real outage would take.
    test "an integration auto-paused after a too_many_pages streak is not re-enqueued" do
      with_config(:tymeslot, :sync_failure_unhealthy_threshold, 2)

      integration = insert(:calendar_integration, provider: "google", is_active: true)

      stub(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :too_many_pages, "Event listing exceeded 200 pages of 2500 events"}
      end)

      for _cycle <- 1..2 do
        assert {:discard, _reason} =
                 perform_job(SyncGoogleCalendarWorker, %{
                   "calendar_integration_id" => integration.id
                 })
      end

      state = Monitor.get_state(:calendar, integration.id, integration.user_id)
      assert state.status == :unhealthy
      assert state.consecutive_hard_failures == 0

      old_unhealthy = DateTime.add(DateTime.utc_now(), -15 * 24 * 3600, :second)

      IntegrationHealthStateQueries.update_fields(:calendar, integration.id,
        became_unhealthy_at: old_unhealthy
      )

      assert :ok = IntegrationAutoPauseWorker.perform(%Oban.Job{})

      {:ok, paused} = CalendarIntegrationQueries.get(integration.id)
      assert paused.is_active == false

      assert :ok = perform_job(FallbackSyncSweepWorker, %{})

      refute_enqueued(
        worker: SyncGoogleCalendarWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end
  end
end
