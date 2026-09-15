defmodule Tymeslot.Workers.SyncGoogleCalendarWorkerTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.HealthCheck.Monitor
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  defp health(integration), do: Monitor.get_state(:calendar, integration.id, integration.user_id)

  setup :verify_on_exit!

  describe "perform/1 - integration not found" do
    test "discards job when integration does not exist" do
      assert {:discard, "Integration not found"} =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => 999_999_999
               })
    end
  end

  describe "perform/1 - unauthorized" do
    test "returns :ok and discards quietly on auth error" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: "valid-sync-token"
        )

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :unauthorized, "Token revoked"}
      end)

      assert :ok =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })
    end
  end

  describe "perform/1 - successful incremental sync" do
    test "returns :ok and persists sync token when events are fetched" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: "old-sync-token"
        )

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:ok, %{events: [], next_sync_token: "new-sync-token-abc"}}
      end)

      assert :ok =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      # persist_sync_state/2 swallows a failed update into :ok, so the return
      # value alone says nothing about the token having been stored.
      reloaded = Repo.get!(CalendarIntegrationSchema, integration.id)

      assert reloaded.google_sync_token == "new-sync-token-abc"
      assert reloaded.last_external_sync_at
    end
  end

  describe "perform/1 - circuit breaker open" do
    test "snoozes for 120 seconds when circuit is open" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: "valid-sync-token"
        )

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :circuit_open}
      end)

      assert {:snooze, 120} =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })
    end
  end

  describe "perform/1 - pagination cap exceeded" do
    test "discards the job instead of retrying when incremental listing exceeds the page cap" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: "valid-sync-token"
        )

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :too_many_pages, "Event listing exceeded 200 pages of 2500 events"}
      end)

      assert {:discard, reason} =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert reason =~ "exceeded 200 pages"
    end

    test "records the cap hit against the integration's health, the same as CalDAV does for its own sync failures" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: "valid-sync-token"
        )

      assert health(integration).consecutive_sync_failures == 0

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :too_many_pages, "Event listing exceeded 200 pages of 2500 events"}
      end)

      assert {:discard, _reason} =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert health(integration).consecutive_sync_failures == 1
    end

    test "a streak of cap hits eventually forces the integration unhealthy" do
      with_config(:tymeslot, :sync_failure_unhealthy_threshold, 2)

      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: "valid-sync-token"
        )

      stub(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :too_many_pages, "Event listing exceeded 200 pages of 2500 events"}
      end)

      for _cycle <- 1..2 do
        assert {:discard, _reason} =
                 perform_job(SyncGoogleCalendarWorker, %{
                   "calendar_integration_id" => integration.id
                 })
      end

      state = health(integration)
      assert state.consecutive_sync_failures == 2
      assert state.status == :unhealthy
      assert %DateTime{} = state.became_unhealthy_at
    end

    test "a subsequent successful sync clears the streak the cap hits raised" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: "valid-sync-token"
        )

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :too_many_pages, "Event listing exceeded 200 pages of 2500 events"}
      end)

      assert {:discard, _reason} =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert health(integration).consecutive_sync_failures == 1

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:ok, %{events: [], next_sync_token: "new-sync-token-after-recovery"}}
      end)

      assert :ok =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert health(integration).consecutive_sync_failures == 0
    end

    test "a cycle whose secondary calendar fails does not clear the streak" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: "valid-sync-token",
          default_booking_calendar_id: "primary",
          calendar_list: [
            %{"id" => "primary", "selected" => true, "name" => "Primary"},
            %{"id" => "work@example.com", "selected" => true, "name" => "Work"}
          ]
        )

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :too_many_pages, "Event listing exceeded 200 pages of 2500 events"}
      end)

      assert {:discard, _reason} =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert health(integration).consecutive_sync_failures == 1

      # The primary listing succeeds and its sync state is persisted, but the
      # secondary calendar fails, so the cycle as a whole has not succeeded.
      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:ok, %{events: [], next_sync_token: "new-sync-token"}}
      end)

      expect(GoogleCalendarAPIMock, :list_events, fn _integration,
                                                     "work@example.com",
                                                     _start,
                                                     _end ->
        {:error, :server_error, "Google returned 500"}
      end)

      assert {:error, _reason} =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert health(integration).consecutive_sync_failures == 1
    end
  end
end
