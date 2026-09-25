defmodule Tymeslot.Workers.SyncGoogleCalendarWorkerEventMappingTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar

  use Oban.Testing, repo: Tymeslot.Repo
  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.AdminAlertsCaptureHelpers
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

  describe "perform/1 - invalid events" do
    setup :capture_admin_alerts

    test "a run raises one operator alert for every event it skipped, and caches the rest" do
      integration =
        insert(:calendar_integration, provider: "google", google_sync_token: "valid-token")

      valid =
        Enum.map(1..2, fn n ->
          %{
            "id" => "google-valid-#{n}",
            "iCalUID" => "valid-#{n}@google.com",
            "status" => "confirmed",
            "start" => %{"dateTime" => "2030-03-1#{n}T10:00:00Z"},
            "end" => %{"dateTime" => "2030-03-1#{n}T11:00:00Z"}
          }
        end)

      # No start or end: `CalendarEvent.new/1` rejects each of these.
      invalid =
        Enum.map(1..3, &%{"id" => "google-bad-#{&1}", "status" => "confirmed"})

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:ok, %{events: Enum.concat([hd(valid)], invalid ++ tl(valid)), next_sync_token: "t"}}
      end)

      capture_log(fn ->
        assert :ok =
                 perform_job(SyncGoogleCalendarWorker, %{
                   "calendar_integration_id" => integration.id
                 })
      end)

      cached =
        ProviderCalendarEventSchema
        |> Repo.all()
        |> Enum.filter(&(&1.calendar_integration_id == integration.id))
        |> Enum.map(& &1.provider_event_id)
        |> Enum.sort()

      assert cached == ["google-valid-1", "google-valid-2"]

      assert_received {:send_alert, :invalid_calendar_event, payload}
      refute_received {:send_alert, :invalid_calendar_event, _second}

      assert payload.count == 3
      assert payload.provider == :google
      assert payload.calendar_integration_id == integration.id

      assert payload.sample_events =~
               ~r/^google-bad-1 \(.+\); google-bad-2 \(.+\); google-bad-3 \(.+\)$/
    end
  end
end
