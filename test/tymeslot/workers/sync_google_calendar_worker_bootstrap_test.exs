defmodule Tymeslot.Workers.SyncGoogleCalendarWorkerBootstrapTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  setup :verify_on_exit!

  describe "perform/1 - booking calendar no longer exists (HTTP 404)" do
    test "flags the integration for reconnection and discards on incremental 404" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: "valid-token"
        )

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :not_found, "Calendar not found"}
      end)

      assert {:discard, _reason} =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      {:ok, refreshed} = CalendarIntegrationQueries.get(integration.id)
      assert refreshed.needs_reauth == true
      assert refreshed.sync_error =~ "no longer exists"
    end

    test "flags the integration for reconnection and discards on bootstrap 404" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: nil
        )

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :no_sync_token}
      end)

      expect(GoogleCalendarAPIMock, :bootstrap_sync, fn _integration ->
        {:error, :not_found, "Calendar not found"}
      end)

      assert {:discard, _reason} =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      {:ok, refreshed} = CalendarIntegrationQueries.get(integration.id)
      assert refreshed.needs_reauth == true
    end
  end

  describe "perform/1 - sync token expired (HTTP 410)" do
    test "re-bootstraps and persists events + fresh sync token when token is gone" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: "expired-sync-token"
        )

      event = %{
        "id" => "google-event-resync",
        "iCalUID" => "resync-uid@google.com",
        "summary" => "After resync",
        "status" => "confirmed",
        "start" => %{"dateTime" => "2030-05-01T10:00:00Z"},
        "end" => %{"dateTime" => "2030-05-01T11:00:00Z"}
      }

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :gone, "Sync token expired"}
      end)

      expect(GoogleCalendarAPIMock, :bootstrap_sync, fn _integration ->
        {:ok, %{events: [event], next_sync_token: "fresh-token-after-gone"}}
      end)

      assert :ok =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      cached = Repo.get_by(ProviderCalendarEventSchema, uid: "resync-uid@google.com")
      assert cached != nil
      assert cached.summary == "After resync"

      {:ok, refreshed} =
        CalendarIntegrationQueries.get(integration.id)

      assert refreshed.google_sync_token == "fresh-token-after-gone"
    end
  end

  describe "perform/1 - initial bootstrap (no sync token)" do
    test "fresh integration backfills events and persists sync token regardless of webhook URL" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: nil
        )

      events = [
        %{
          "id" => "google-backfill-1",
          "iCalUID" => "backfill-1@google.com",
          "summary" => "Existing event A",
          "status" => "confirmed",
          "start" => %{"dateTime" => "2030-06-01T10:00:00Z"},
          "end" => %{"dateTime" => "2030-06-01T11:00:00Z"}
        },
        %{
          "id" => "google-backfill-2",
          "iCalUID" => "backfill-2@google.com",
          "summary" => "Existing event B",
          "status" => "confirmed",
          "start" => %{"date" => "2030-06-02"},
          "end" => %{"date" => "2030-06-03"}
        }
      ]

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :no_sync_token}
      end)

      expect(GoogleCalendarAPIMock, :bootstrap_sync, fn _integration ->
        {:ok, %{events: events, next_sync_token: "initial-sync-token"}}
      end)

      assert :ok =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      cached_a = Repo.get_by(ProviderCalendarEventSchema, uid: "backfill-1@google.com")
      cached_b = Repo.get_by(ProviderCalendarEventSchema, uid: "backfill-2@google.com")
      assert cached_a != nil
      assert cached_a.summary == "Existing event A"
      assert cached_b != nil
      assert cached_b.all_day == true

      {:ok, refreshed} =
        CalendarIntegrationQueries.get(integration.id)

      assert refreshed.google_sync_token == "initial-sync-token"
    end

    test "bootstrap snoozes when circuit breaker is open" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: nil
        )

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :no_sync_token}
      end)

      expect(GoogleCalendarAPIMock, :bootstrap_sync, fn _integration ->
        {:error, :circuit_open}
      end)

      assert {:snooze, 120} =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })
    end

    test "bootstrap tolerates unauthorised errors without crashing" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: nil
        )

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :no_sync_token}
      end)

      expect(GoogleCalendarAPIMock, :bootstrap_sync, fn _integration ->
        {:error, :unauthorized, "Token revoked"}
      end)

      assert :ok =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })
    end

    test "bootstrap returns error and allows Oban to retry on network error" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: nil
        )

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :no_sync_token}
      end)

      expect(GoogleCalendarAPIMock, :bootstrap_sync, fn _integration ->
        {:error, :rate_limited, "Quota exceeded"}
      end)

      assert {:error, "Quota exceeded"} =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })
    end

    test "bootstrap returns error on bare 2-tuple from token layer without crashing" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: nil
        )

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :no_sync_token}
      end)

      expect(GoogleCalendarAPIMock, :bootstrap_sync, fn _integration ->
        {:error, :lock_timeout}
      end)

      assert {:error, :lock_timeout} =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })
    end
  end
end
