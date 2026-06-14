defmodule Tymeslot.Workers.SyncGoogleCalendarWorkerMultiCalendarTest do
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
end
