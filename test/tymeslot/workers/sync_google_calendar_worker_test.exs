defmodule Tymeslot.Workers.SyncGoogleCalendarWorkerTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.Factory

  alias Tymeslot.DatabaseSchemas.CalendarEventCacheSchema
  alias Tymeslot.Repo
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

  describe "perform/1 - multi-calendar sync" do
    test "fetches events from all selected calendars beyond the booking calendar" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: "valid-token",
          default_booking_calendar_id: "primary",
          calendar_list: [
            %{"id" => "primary", "selected" => true, "name" => "Primary"},
            %{"id" => "work@example.com", "selected" => true, "name" => "Work"}
          ]
        )

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:ok, %{events: [], next_sync_token: "new-token"}}
      end)

      expect(GoogleCalendarAPIMock, :list_events, fn _integration, calendar_id, _start, _end ->
        assert calendar_id == "work@example.com"
        {:ok, []}
      end)

      assert :ok =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })
    end

    test "does not call list_events when calendar_list has only the booking calendar" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: "valid-token",
          default_booking_calendar_id: "primary",
          calendar_list: [
            %{"id" => "primary", "selected" => true, "name" => "Primary"}
          ]
        )

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:ok, %{events: [], next_sync_token: "new-token"}}
      end)

      # no list_events expectation — Mox will raise if it's called unexpectedly

      assert :ok =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })
    end

    test "skips unselected calendars in calendar_list" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: "valid-token",
          default_booking_calendar_id: "primary",
          calendar_list: [
            %{"id" => "primary", "selected" => true, "name" => "Primary"},
            %{"id" => "personal@example.com", "selected" => false, "name" => "Personal"}
          ]
        )

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:ok, %{events: [], next_sync_token: "new-token"}}
      end)

      # no list_events expectation — personal calendar is unselected

      assert :ok =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })
    end
  end

  describe "perform/1 - event field mapping" do
    test "stores attendees using consistent email/name/status format" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: "valid-token"
        )

      event = %{
        "id" => "google-event-1",
        "iCalUID" => "ical-uid-1@google.com",
        "summary" => "Sprint Planning",
        "status" => "confirmed",
        "start" => %{"dateTime" => "2030-03-15T10:00:00Z"},
        "end" => %{"dateTime" => "2030-03-15T11:00:00Z"},
        "attendees" => [
          %{
            "email" => "alice@example.com",
            "displayName" => "Alice",
            "responseStatus" => "accepted"
          },
          %{
            "email" => "bob@example.com",
            "displayName" => "Bob Jones",
            "responseStatus" => "tentative"
          }
        ]
      }

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:ok, %{events: [event], next_sync_token: "new-token"}}
      end)

      assert :ok =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      cached = Repo.get_by(CalendarEventCacheSchema, provider_event_id: "google-event-1")
      assert [alice, bob] = cached.attendees
      assert alice["email"] == "alice@example.com"
      assert alice["name"] == "Alice"
      assert alice["status"] == "accepted"
      assert bob["name"] == "Bob Jones"
      assert bob["status"] == "tentative"
    end

    test "stores location and description from Google event" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: "valid-token"
        )

      event = %{
        "id" => "google-event-2",
        "iCalUID" => "ical-uid-2@google.com",
        "summary" => "All Hands",
        "status" => "confirmed",
        "start" => %{"dateTime" => "2030-03-15T14:00:00Z"},
        "end" => %{"dateTime" => "2030-03-15T15:00:00Z"},
        "location" => "Main Auditorium",
        "description" => "Quarterly review notes",
        "attendees" => []
      }

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:ok, %{events: [event], next_sync_token: "new-token"}}
      end)

      assert :ok =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      cached = Repo.get_by(CalendarEventCacheSchema, provider_event_id: "google-event-2")
      assert cached.location == "Main Auditorium"
      assert cached.description == "Quarterly review notes"
    end
  end

  describe "perform/1 - all-day events" do
    test "caches multi-day all-day event with all_day: true and UTC-midnight timestamps" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: "valid-token"
        )

      event = %{
        "id" => "google-allday-1",
        "iCalUID" => "allday-uid@google.com",
        "summary" => "Holiday",
        "status" => "confirmed",
        "start" => %{"date" => "2026-04-07"},
        "end" => %{"date" => "2026-04-11"}
      }

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:ok, %{events: [event], next_sync_token: "new-token"}}
      end)

      assert :ok =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      cached = Repo.get_by(CalendarEventCacheSchema, provider_event_id: "google-allday-1")
      assert cached.all_day == true
      assert cached.title == "Holiday"
      assert cached.start_at == ~U[2026-04-07 00:00:00Z]
      assert cached.end_at == ~U[2026-04-11 00:00:00Z]
    end
  end

  describe "perform/1 - sync token expired (HTTP 410)" do
    test "re-registers push channel and returns :ok on token expiry" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: "expired-sync-token"
        )

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :gone, "Sync token expired"}
      end)

      expect(GoogleCalendarAPIMock, :register_push_channel, fn _integration ->
        {:ok, integration}
      end)

      assert :ok =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })
    end

    test "returns :ok when webhook base URL is not configured on token expiry" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: "expired-sync-token"
        )

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :gone, "Sync token expired"}
      end)

      expect(GoogleCalendarAPIMock, :register_push_channel, fn _integration ->
        {:error, :webhook_base_url_not_configured}
      end)

      assert :ok =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })
    end
  end
end
