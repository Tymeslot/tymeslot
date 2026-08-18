defmodule Tymeslot.Workers.SyncGoogleCalendarWorkerTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

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
end
