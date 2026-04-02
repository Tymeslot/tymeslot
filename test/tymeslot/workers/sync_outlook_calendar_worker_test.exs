defmodule Tymeslot.Workers.SyncOutlookCalendarWorkerTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.SyncOutlookCalendarWorker

  # Use global mode so mocks are visible from the circuit breaker GenServer process
  setup :set_mox_global
  setup :verify_on_exit!

  defp outlook_integration(attrs \\ []) do
    defaults = [
      provider: "outlook",
      access_token_encrypted: Encryption.encrypt("test-access-token"),
      refresh_token_encrypted: Encryption.encrypt("test-refresh-token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    ]

    insert(:calendar_integration, Keyword.merge(defaults, attrs))
  end

  describe "perform/1 - integration not found" do
    test "discards job when integration does not exist" do
      assert {:discard, "Integration not found"} =
               perform_job(SyncOutlookCalendarWorker, %{
                 "calendar_integration_id" => 999_999_999,
                 "graph_resource_id" => "some-resource-id"
               })
    end
  end

  describe "perform/1 - missing graph_resource_id" do
    test "discards job when graph_resource_id is absent" do
      integration = outlook_integration()

      assert {:discard, "graph_resource_id required — Outlook syncs are webhook-driven"} =
               perform_job(SyncOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })
    end
  end

  describe "perform/1 - unauthorized" do
    test "returns :ok on auth error from event fetch" do
      integration = outlook_integration()

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %{status: 401, body: ~s({"error":"unauthorized"})}}
      end)

      assert :ok =
               perform_job(SyncOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id,
                 "graph_resource_id" => "event-abc-123"
               })
    end
  end

  describe "perform/1 - circuit breaker open" do
    test "snoozes for 120 seconds when circuit is open" do
      integration = outlook_integration()

      # Trip the circuit breaker by making enough failing calls through it.
      # The outlook breaker has failure_threshold: 5.
      for _n <- 1..6 do
        CalendarCircuitBreaker.call(:outlook, fn -> raise "simulated failure" end)
      end

      # The HTTP call now happens before the circuit breaker check (for 404/401 extraction),
      # so we need a mock that returns a normal (non-404/401) response. The circuit breaker
      # will reject the result before it matters.
      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: ~s({"id":"event-abc-123","subject":"Test"})}}
      end)

      assert {:snooze, 120} =
               perform_job(SyncOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id,
                 "graph_resource_id" => "event-abc-123"
               })

      # Reset to avoid polluting other tests
      CalendarCircuitBreaker.reset(:outlook)
    end
  end

  describe "perform/1 - all-day events" do
    test "caches multi-day all-day event with all_day: true and UTC-midnight timestamps" do
      integration = outlook_integration()

      graph_event_json =
        Jason.encode!(%{
          "id" => "outlook-allday-1",
          "iCalUId" => "allday-uid@outlook.com",
          "subject" => "Holiday",
          "isAllDay" => true,
          "start" => %{"dateTime" => "2026-04-07T00:00:00.0000000", "timeZone" => "UTC"},
          "end" => %{"dateTime" => "2026-04-11T00:00:00.0000000", "timeZone" => "UTC"},
          "showAs" => "free",
          "attendees" => [],
          "type" => "singleInstance"
        })

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: graph_event_json}}
      end)

      assert :ok =
               perform_job(SyncOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id,
                 "graph_resource_id" => "outlook-allday-1"
               })

      cached =
        Repo.get_by(
          Tymeslot.DatabaseSchemas.CalendarEventCacheSchema,
          provider_event_id: "outlook-allday-1"
        )

      assert cached.all_day == true
      assert cached.title == "Holiday"
      assert cached.start_at == ~U[2026-04-07 00:00:00Z]
      assert cached.end_at == ~U[2026-04-11 00:00:00Z]
      assert cached.status == "free"
    end
  end

  describe "perform/1 - event deletion (404)" do
    test "removes cached event and returns :ok when Graph returns 404" do
      integration = outlook_integration()

      insert(:calendar_event_cache,
        calendar_integration: integration,
        provider_event_id: "deleted-event-123",
        uid: "ical-uid-deleted@test"
      )

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %{status: 404, body: ~s({"error":"not_found"})}}
      end)

      # 404 is handled outside the circuit breaker — does not count as failure
      assert :ok =
               perform_job(SyncOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id,
                 "graph_resource_id" => "deleted-event-123"
               })

      # The cached event IS removed because handle_event_deleted is reached
      remaining =
        Repo.all(
          from e in Tymeslot.DatabaseSchemas.CalendarEventCacheSchema,
            where:
              e.calendar_integration_id == ^integration.id and
                e.provider_event_id == "deleted-event-123"
        )

      assert Enum.empty?(remaining)
    end
  end
end
