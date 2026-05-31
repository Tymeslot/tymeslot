defmodule Tymeslot.Integrations.Calendar.Outlook.DeltaSyncTest do
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integrations

  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Outlook.DeltaSync
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Security.Encryption

  # The circuit breaker runs in a GenServer process that is separate from the
  # test process. Use global mode so mocks are visible from that process.
  setup :set_mox_global
  setup :verify_on_exit!

  defp outlook_integration(attrs) do
    defaults = [
      provider: "outlook",
      access_token_encrypted: Encryption.encrypt("test-access-token"),
      refresh_token_encrypted: Encryption.encrypt("test-refresh-token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    ]

    insert(:calendar_integration, Keyword.merge(defaults, attrs))
  end

  defp graph_event(overrides) do
    Map.merge(
      %{
        "id" => "graph-id-#{System.unique_integer([:positive])}",
        "iCalUId" => "ical-uid-#{System.unique_integer([:positive])}",
        "subject" => "Test Event",
        "body" => %{"content" => ""},
        "location" => %{"displayName" => ""},
        "showAs" => "busy",
        "sensitivity" => "normal",
        "isAllDay" => false,
        "isCancelled" => false,
        "responseStatus" => %{"response" => "accepted"},
        "start" => %{"dateTime" => "2024-03-15T14:00:00Z", "timeZone" => "UTC"},
        "end" => %{"dateTime" => "2024-03-15T15:00:00Z", "timeZone" => "UTC"},
        "organizer" => %{
          "emailAddress" => %{"address" => "org@example.com", "name" => "Organiser"}
        },
        "attendees" => [],
        "reminderMinutesBeforeStart" => 15,
        "recurrence" => nil,
        "seriesMasterId" => nil
      },
      overrides
    )
  end

  describe "fetch_and_apply/1 - happy path with events" do
    test "upserts events, persists new delta link, and broadcasts cache update" do
      integration =
        outlook_integration(
          graph_delta_link:
            "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=old-token"
        )

      user_id = integration.user_id
      Phoenix.PubSub.subscribe(Tymeslot.PubSub, "calendar_events:#{user_id}")

      event1 = graph_event(%{"iCalUId" => "uid-event-1"})
      event2 = graph_event(%{"iCalUId" => "uid-event-2"})
      new_delta_link = "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=fresh"

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "value" => [event1, event2],
               "@odata.deltaLink" => new_delta_link
             })
         }}
      end)

      assert :ok = DeltaSync.fetch_and_apply(integration)

      # Events should be upserted into the cache.
      assert {:ok, _event1} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "uid-event-1")

      assert {:ok, _event2} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "uid-event-2")

      # The new delta link should be persisted.
      {:ok, updated} = CalendarIntegrationQueries.get(integration.id)
      assert updated.graph_delta_link == new_delta_link

      # A cache-update broadcast should have been sent.
      assert_receive {:calendar_events_updated, ^user_id, uids}
      assert "uid-event-1" in uids
      assert "uid-event-2" in uids
    end
  end

  describe "fetch_and_apply/1 - empty events" do
    test "persists new delta link without upserting any events" do
      integration =
        outlook_integration(
          graph_delta_link:
            "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=old-token"
        )

      new_delta_link =
        "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=fresh-empty"

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "value" => [],
               "@odata.deltaLink" => new_delta_link
             })
         }}
      end)

      assert :ok = DeltaSync.fetch_and_apply(integration)

      {:ok, updated} = CalendarIntegrationQueries.get(integration.id)
      assert updated.graph_delta_link == new_delta_link
    end
  end

  describe "fetch_and_apply/1 - 410 expired delta link" do
    test "clears the stored delta link and returns :error" do
      integration =
        outlook_integration(
          graph_delta_link:
            "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=expired"
        )

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 410, body: ~s({"error":"gone"})}}
      end)

      log =
        capture_log(fn ->
          assert :error = DeltaSync.fetch_and_apply(integration)
        end)

      assert log =~ "Outlook delta link expired"

      # The stored delta link must be cleared so the bootstrap path re-runs.
      {:ok, updated} = CalendarIntegrationQueries.get(integration.id)
      assert is_nil(updated.graph_delta_link)
    end
  end

  describe "fetch_and_apply/1 - nil delta link in response (I-17)" do
    test "does not overwrite a stored delta link when the response contains no link" do
      stored_link =
        "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=preserved"

      integration = outlook_integration(graph_delta_link: stored_link)

      # Response has events but neither @odata.deltaLink nor @odata.nextLink.
      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: Jason.encode!(%{"value" => []})
         }}
      end)

      assert :ok = DeltaSync.fetch_and_apply(integration)

      # The stored link must be unchanged — nil must not overwrite it.
      {:ok, updated} = CalendarIntegrationQueries.get(integration.id)
      assert updated.graph_delta_link == stored_link
    end
  end

  describe "fetch_and_apply/1 - token refresh 3-tuple error" do
    # Regression: a 3-tuple api_error from refresh_token used to escape the
    # case clause in the fetch function and crash the caller. The fix wraps it
    # into the catch-all handle_fetch_result clause that logs and returns :error.
    test "logs and continues when token refresh returns an api_error 3-tuple" do
      insert(:calendar_integration,
        provider: "outlook",
        is_active: true,
        graph_delta_link:
          "https://graph.microsoft.com/v1.0/me/calendarView/delta?$skiptoken=fake-skiptoken",
        token_expires_at: nil
      )

      # Force refresh to return a 3-tuple api_error.
      expect(OutlookCalendarAPIMock, :refresh_token, fn _integration ->
        {:error, :unauthorized, "Token refresh failed"}
      end)

      # Without the 3-tuple fix, this raised CaseClauseError and the caller
      # would receive {:error, exception}.
      log =
        capture_log(fn ->
          integration =
            insert(:calendar_integration,
              provider: "outlook",
              is_active: true,
              graph_delta_link:
                "https://graph.microsoft.com/v1.0/me/calendarView/delta?$skiptoken=fake-skiptoken",
              token_expires_at: nil
            )

          assert :error = DeltaSync.fetch_and_apply(integration)
        end)

      assert log =~ "Outlook token refresh failed"
    end
  end

  describe "fetch_and_apply/1 - stale delta link with unsupported query parameters" do
    # A stored delta link written before the fix may carry $select/$expand —
    # Microsoft Graph rejects these on calendarView/delta with HTTP 400. The
    # module must strip them before reuse.
    test "strips unsupported query parameters from a stale stored delta link" do
      stale_delta_link =
        "https://graph.microsoft.com/v1.0/me/calendarView/delta?" <>
          "$deltatoken=stale-token&$select=id,subject&$expand=extendedProperties"

      integration =
        outlook_integration(graph_delta_link: stale_delta_link)

      expect(Tymeslot.HTTPClientMock, :request, fn :get, url, _body, _headers, _opts ->
        assert String.contains?(url, "$deltatoken=stale-token")
        refute String.contains?(String.downcase(url), "$select")
        refute String.contains?(String.downcase(url), "$expand")

        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "value" => [],
               "@odata.deltaLink" =>
                 "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=fresh"
             })
         }}
      end)

      assert :ok = DeltaSync.fetch_and_apply(integration)
    end
  end

  describe "fetch_and_apply/1 - obsolete /events/delta link" do
    # Earlier bootstraps wrote a `/me/events/delta` link whose $deltatoken
    # froze the date window for the life of the integration — new events
    # outside that window never reached the cache. The module must detect
    # the obsolete endpoint, clear the link, and let the next sync run a
    # re-bootstrap via `/me/calendarView/delta`. No HTTP must be issued
    # against the bad URL.
    test "clears the link and returns :error without making any HTTP request" do
      obsolete_link =
        "https://graph.microsoft.com/v1.0/me/events/delta?$deltatoken=frozen-window"

      integration = outlook_integration(graph_delta_link: obsolete_link)

      # Mox would raise if any HTTP request fires — the obsolete link must
      # never be sent back to Graph.

      assert :error = DeltaSync.fetch_and_apply(integration)

      {:ok, reloaded} = CalendarIntegrationQueries.get(integration.id)
      assert is_nil(reloaded.graph_delta_link)
    end
  end
end
