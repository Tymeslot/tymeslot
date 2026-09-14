defmodule Tymeslot.Integrations.Calendar.Google.CalendarAPIPaginationTest do
  # async: false: :google_oauth is read by the OAuth helpers and by OAuthStateGuard on the
  # web path, both reachable from other tests.
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  # Both Google listings walk `nextPageToken` through one shared paginator.
  # They were copy-paste twins until they were merged, and the incremental
  # half spent that time with no pagination at all, so the cases proving the
  # loop, the page size, the error passthrough and the page cap live together
  # here rather than split across the two entry points that share them.

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  describe "bootstrap_sync/1" do
    # bootstrap_sync/1 passes the HTTP call through CalendarCircuitBreaker, which
    # runs the function inside the GenServer process. Mox expectations are
    # process-scoped, so we must explicitly allow the circuit breaker process to
    # use the mock before each test in this describe block.
    setup do
      breaker_pid = Process.whereis(:calendar_breaker_google)
      Mox.allow(Tymeslot.HTTPClientMock, self(), breaker_pid)
      :ok
    end

    test "single-page response returns events and sync token with correct time params" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
          default_booking_calendar_id: "work@example.com"
        )

      expect(Tymeslot.HTTPClientMock, :request, fn :get, url, _body, _headers, _opts ->
        assert String.starts_with?(
                 url,
                 "https://www.googleapis.com/calendar/v3/calendars/work@example.com/events"
               )

        assert String.contains?(url, "timeMin=")
        assert String.contains?(url, "timeMax=")
        assert String.contains?(url, "singleEvents=true")
        assert String.contains?(url, "maxResults=2500")
        refute String.contains?(url, "pageToken=")
        refute String.contains?(url, "syncToken=")

        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "items" => [
                 %{"id" => "evt1", "summary" => "Standup"},
                 %{"id" => "evt2", "summary" => "Review"}
               ],
               "nextSyncToken" => "sync_abc123"
             })
         }}
      end)

      assert {:ok, %{events: events, next_sync_token: "sync_abc123"}} =
               CalendarAPI.bootstrap_sync(integration)

      assert length(events) == 2
      assert Enum.map(events, & &1["id"]) == ["evt1", "evt2"]
    end

    test "multi-page response accumulates events across pages in order" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
        )

      # First call returns a nextPageToken; second call returns the final page.
      expect(Tymeslot.HTTPClientMock, :request, 2, fn :get, url, _body, _headers, _opts ->
        if String.contains?(url, "pageToken=page2") do
          {:ok,
           %Req.Response{
             status: 200,
             body:
               Jason.encode!(%{
                 "items" => [%{"id" => "evt3"}, %{"id" => "evt4"}],
                 "nextSyncToken" => "sync_final"
               })
           }}
        else
          {:ok,
           %Req.Response{
             status: 200,
             body:
               Jason.encode!(%{
                 "items" => [%{"id" => "evt1"}, %{"id" => "evt2"}],
                 "nextPageToken" => "page2"
               })
           }}
        end
      end)

      assert {:ok, %{events: events, next_sync_token: "sync_final"}} =
               CalendarAPI.bootstrap_sync(integration)

      assert Enum.map(events, & &1["id"]) == ["evt1", "evt2", "evt3", "evt4"]
    end
  end

  describe "list_events_incremental/1" do
    setup do
      breaker_pid = Process.whereis(:calendar_breaker_google)
      Mox.allow(Tymeslot.HTTPClientMock, self(), breaker_pid)
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
          google_sync_token: "sync_old"
        )

      %{integration: integration}
    end

    defp sync_response(items, extra),
      do:
        {:ok,
         %Req.Response{status: 200, body: Jason.encode!(Map.merge(%{"items" => items}, extra))}}

    test "single-page response returns events and the sync token", %{integration: integration} do
      expect(Tymeslot.HTTPClientMock, :request, fn :get, url, _body, _headers, _opts ->
        assert String.contains?(url, "syncToken=sync_old")
        refute String.contains?(url, "pageToken=")
        sync_response([%{"id" => "evt1"}], %{"nextSyncToken" => "sync_new"})
      end)

      assert {:ok, %{events: [%{"id" => "evt1"}], next_sync_token: "sync_new"}} =
               CalendarAPI.list_events_incremental(integration)
    end

    # Regression: a multi-page delta was truncated after page 1, and since
    # Google only returns nextSyncToken on the final page, the stored token
    # was never advanced; every later run re-fetched the same stale page.
    test "multi-page response accumulates all events and returns the final sync token",
         %{integration: integration} do
      expect(Tymeslot.HTTPClientMock, :request, 2, fn :get, url, _body, _headers, _opts ->
        if String.contains?(url, "pageToken=page2") do
          sync_response([%{"id" => "evt3"}, %{"id" => "evt4"}], %{"nextSyncToken" => "sync_final"})
        else
          assert String.contains?(url, "syncToken=sync_old")
          sync_response([%{"id" => "evt1"}, %{"id" => "evt2"}], %{"nextPageToken" => "page2"})
        end
      end)

      assert {:ok, %{events: events, next_sync_token: "sync_final"}} =
               CalendarAPI.list_events_incremental(integration)

      assert Enum.map(events, & &1["id"]) == ["evt1", "evt2", "evt3", "evt4"]
    end

    test "asks for a full page, as the bootstrap listing does", %{integration: integration} do
      # Both listings share one paginator precisely so this cannot drift: the
      # incremental path used to take Google's default of 250 per page while
      # bootstrap asked for 2500, so a backlog cost roughly nine times the
      # round-trips it needed.
      expect(Tymeslot.HTTPClientMock, :request, fn :get, url, _body, _headers, _opts ->
        assert String.contains?(url, "maxResults=2500")
        sync_response([], %{"nextSyncToken" => "sync_new"})
      end)

      assert {:ok, %{events: []}} = CalendarAPI.list_events_incremental(integration)
    end

    test "a 410 mid-pagination is returned untouched for the bootstrap fallback",
         %{integration: integration} do
      # The circuit breaker deliberately does not wrap the calendar clients'
      # 3-tuple, so this must arrive at SyncGoogleCalendarWorker as a bare
      # {:error, :gone, _}: that is what it matches on to fall back to a full
      # sync. Wrapping it would silently disable the fallback, and a 410 on
      # page two was previously covered nowhere at all.
      expect(Tymeslot.HTTPClientMock, :request, 2, fn :get, url, _body, _headers, _opts ->
        if String.contains?(url, "pageToken=page2") do
          {:ok, %Req.Response{status: 410, body: ""}}
        else
          sync_response([%{"id" => "evt1"}], %{"nextPageToken" => "page2"})
        end
      end)

      assert {:error, :gone, _message} = CalendarAPI.list_events_incremental(integration)
    end

    test "a provider that never advances its page token is cut off, not looped on",
         %{integration: integration} do
      # Neither loop had any bound before. A repeated page token would hold one
      # of the ten calendar_events queue slots for ever, with nothing logged.
      # Exactly @max_pages fetches, then the loop stops without a 201st.
      expect(Tymeslot.HTTPClientMock, :request, 200, fn :get, _url, _body, _headers, _opts ->
        sync_response([%{"id" => "evt"}], %{"nextPageToken" => "same_token_every_time"})
      end)

      assert {:error, :too_many_pages, message} =
               CalendarAPI.list_events_incremental(integration)

      assert message =~ "200 pages"
    end
  end
end
