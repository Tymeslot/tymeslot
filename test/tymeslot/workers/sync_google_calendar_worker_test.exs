defmodule Tymeslot.Workers.SyncGoogleCalendarWorkerTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
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

  describe "perform/1 - secondary calendar no longer exists (HTTP 404)" do
    test "completes :ok and de-selects the missing calendar so it is not re-fetched" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: "valid-token",
          default_booking_calendar_id: "primary",
          calendar_list: [
            %{"id" => "primary", "selected" => true, "name" => "Primary"},
            %{"id" => "deleted@example.com", "selected" => true, "name" => "Deleted"}
          ]
        )

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:ok, %{events: [], next_sync_token: "new-token"}}
      end)

      expect(GoogleCalendarAPIMock, :list_events, fn _integration,
                                                     "deleted@example.com",
                                                     _s,
                                                     _e ->
        {:error, :not_found, "Calendar not found"}
      end)

      assert :ok =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      {:ok, refreshed} = CalendarIntegrationQueries.get(integration.id)

      assert Enum.find(refreshed.calendar_list, &(&1["id"] == "deleted@example.com"))["selected"] ==
               false

      assert Enum.find(refreshed.calendar_list, &(&1["id"] == "primary"))["selected"] == true
    end

    test "de-selects every missing calendar when several 404 in the same run" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: "valid-token",
          default_booking_calendar_id: "primary",
          calendar_list: [
            %{"id" => "primary", "selected" => true, "name" => "Primary"},
            %{"id" => "gone-a@example.com", "selected" => true, "name" => "Gone A"},
            %{"id" => "gone-b@example.com", "selected" => true, "name" => "Gone B"}
          ]
        )

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:ok, %{events: [], next_sync_token: "new-token"}}
      end)

      expect(GoogleCalendarAPIMock, :list_events, 2, fn _integration, _calendar_id, _s, _e ->
        {:error, :not_found, "Calendar not found"}
      end)

      assert :ok =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      {:ok, refreshed} = CalendarIntegrationQueries.get(integration.id)

      selected =
        refreshed.calendar_list
        |> Enum.filter(& &1["selected"])
        |> Enum.map(& &1["id"])

      assert selected == ["primary"]
    end

    test "caches events from a good secondary calendar and de-selects a 404 calendar in the same run" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: "valid-token",
          default_booking_calendar_id: "primary",
          calendar_list: [
            %{"id" => "primary", "selected" => true, "name" => "Primary"},
            %{"id" => "work@example.com", "selected" => true, "name" => "Work"},
            %{"id" => "deleted@example.com", "selected" => true, "name" => "Deleted"}
          ]
        )

      secondary_event = %{
        "id" => "work-event-mixed-1",
        "iCalUID" => "work-mixed-uid-1@google.com",
        "summary" => "Work Meeting",
        "status" => "confirmed",
        "start" => %{"dateTime" => "2030-06-01T10:00:00Z"},
        "end" => %{"dateTime" => "2030-06-01T11:00:00Z"}
      }

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:ok, %{events: [], next_sync_token: "new-token"}}
      end)

      expect(GoogleCalendarAPIMock, :list_events, fn _integration, "work@example.com", _s, _e ->
        {:ok, [secondary_event]}
      end)

      expect(GoogleCalendarAPIMock, :list_events, fn _integration,
                                                     "deleted@example.com",
                                                     _s,
                                                     _e ->
        {:error, :not_found, "Calendar not found"}
      end)

      assert :ok =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      cached = Repo.get_by(ProviderCalendarEventSchema, provider_event_id: "work-event-mixed-1")
      assert cached != nil
      assert cached.provider_calendar_id == "work@example.com"

      {:ok, refreshed} = CalendarIntegrationQueries.get(integration.id)

      assert Enum.find(refreshed.calendar_list, &(&1["id"] == "work@example.com"))["selected"] ==
               true

      assert Enum.find(refreshed.calendar_list, &(&1["id"] == "deleted@example.com"))["selected"] ==
               false
    end

    test "returns {:error, reason} on a non-404 three-tuple instead of crashing" do
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

      expect(GoogleCalendarAPIMock, :list_events, fn _integration, "work@example.com", _s, _e ->
        {:error, :network_error, "Bad gateway"}
      end)

      assert {:error, "Bad gateway"} =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })
    end
  end

  describe "perform/1 - secondary calendar provider_calendar_id" do
    test "tags secondary calendar events with the secondary calendar's ID, not the booking calendar" do
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

      secondary_event = %{
        "id" => "work-event-1",
        "iCalUID" => "work-uid-1@google.com",
        "summary" => "Work Meeting",
        "status" => "confirmed",
        "start" => %{"dateTime" => "2030-06-01T10:00:00Z"},
        "end" => %{"dateTime" => "2030-06-01T11:00:00Z"}
      }

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:ok, %{events: [], next_sync_token: "new-token"}}
      end)

      expect(GoogleCalendarAPIMock, :list_events, fn _integration, calendar_id, _start, _end ->
        assert calendar_id == "work@example.com"
        {:ok, [secondary_event]}
      end)

      assert :ok =
               perform_job(SyncGoogleCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      cached = Repo.get_by(ProviderCalendarEventSchema, provider_event_id: "work-event-1")
      assert cached != nil
      assert cached.provider_calendar_id == "work@example.com"
    end
  end

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
