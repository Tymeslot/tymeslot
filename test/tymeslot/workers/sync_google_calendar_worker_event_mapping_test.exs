defmodule Tymeslot.Workers.SyncGoogleCalendarWorkerEventMappingTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  setup :verify_on_exit!

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

      cached = Repo.get_by(ProviderCalendarEventSchema, provider_event_id: "google-event-1")
      assert [alice, bob] = cached.attendees
      assert alice["email"] == "alice@example.com"
      assert alice["display_name"] == "Alice"
      assert alice["response_status"] == "accepted"
      assert bob["display_name"] == "Bob Jones"
      assert bob["response_status"] == "tentative"
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

      cached = Repo.get_by(ProviderCalendarEventSchema, provider_event_id: "google-event-2")
      assert cached.location == "Main Auditorium"
      assert cached.description == "Quarterly review notes"
    end
  end

  describe "perform/1 - all-day events" do
    test "caches multi-day all-day event with all_day: true and UTC-midnight timestamps" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: "valid-token",
          default_booking_calendar_id: "primary"
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

      cached = Repo.get_by(ProviderCalendarEventSchema, uid: "allday-uid@google.com")
      assert cached.all_day == true
      assert cached.summary == "Holiday"
      assert cached.start_date == ~D[2026-04-07]
      assert cached.end_date == ~D[2026-04-11]
      assert cached.provider_calendar_id == "primary"
    end
  end

  describe "perform/1 - cancelled event handling" do
    test "deletes cached event by uid when iCalUID is present in cancellation delta" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: "valid-token"
        )

      _cached =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          uid: "cancelled-uid@google.com",
          provider_event_id: "google-event-cancel-1"
        )

      cancelled_event = %{
        "id" => "google-event-cancel-1",
        "iCalUID" => "cancelled-uid@google.com",
        "status" => "cancelled"
      }

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:ok, %{events: [cancelled_event], next_sync_token: "new-token"}}
      end)

      assert :ok =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert {:error, :not_found} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "cancelled-uid@google.com")
    end

    test "deletes cached event by provider_event_id when iCalUID is absent in cancellation delta" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: "valid-token"
        )

      cached =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          uid: "full-uid@google.com",
          provider_event_id: "google-event-id-only"
        )

      # Google omits iCalUID for incremental cancellation deltas
      cancelled_event = %{
        "id" => "google-event-id-only",
        "status" => "cancelled"
      }

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:ok, %{events: [cancelled_event], next_sync_token: "new-token"}}
      end)

      assert :ok =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      refute Repo.get(ProviderCalendarEventSchema, cached.id)
    end
  end
end
