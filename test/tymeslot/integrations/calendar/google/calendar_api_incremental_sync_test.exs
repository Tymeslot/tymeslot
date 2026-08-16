defmodule Tymeslot.Integrations.Calendar.Google.CalendarAPIIncrementalSyncTest do
  # The circuit breaker wrapping list_events_incremental/1 is a singleton
  # GenServer shared across the suite, so the mock must be visible from a
  # process other than the test's. Global mode requires async: false.
  use Tymeslot.DataCase, async: false

  @moduletag :integrations

  import Tymeslot.Factory
  import Mox

  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  describe "list_events_incremental/1" do
    # Shares bootstrap_sync/1's circuit-breaker indirection: the HTTP call runs
    # inside the breaker's GenServer, and Mox expectations are process-scoped.
    setup :set_mox_global

    test "paginates until the page carrying the sync token" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
          google_sync_token: "sync_start"
        )

      # Google omits nextSyncToken on every page but the last, and answers a
      # paginated delta with nextPageToken instead. A first page that stops
      # here strands every later page and stores no new token.
      expect(Tymeslot.HTTPClientMock, :request, 2, fn :get, url, _body, _headers, _opts ->
        if String.contains?(url, "pageToken=page2") do
          # The continuation must carry the sync token forward; Google rejects
          # a pageToken presented without the syncToken it was minted under.
          assert String.contains?(url, "syncToken=sync_start")

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
          refute String.contains?(url, "pageToken=")

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
               CalendarAPI.list_events_incremental(integration)

      assert Enum.map(events, & &1["id"]) == ["evt1", "evt2", "evt3", "evt4"]
    end

    test "requests expanded instances so the delta matches the bootstrap listing" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
          default_booking_calendar_id: "work@example.com",
          google_sync_token: "sync_start"
        )

      expect(Tymeslot.HTTPClientMock, :request, fn :get, url, _body, _headers, _opts ->
        assert String.contains?(url, "syncToken=sync_start")
        # Google requires every follow-up sync to repeat the parameters of the
        # listing that minted the token. bootstrap_sync/1 sends singleEvents,
        # so a delta omitting it asks for a differently-shaped feed.
        assert String.contains?(url, "singleEvents=true")
        # timeMin/timeMax are rejected outright alongside a syncToken.
        refute String.contains?(url, "timeMin=")
        refute String.contains?(url, "timeMax=")

        {:ok,
         %Req.Response{
           status: 200,
           body: Jason.encode!(%{"items" => [], "nextSyncToken" => "sync_final"})
         }}
      end)

      assert {:ok, %{events: [], next_sync_token: "sync_final"}} =
               CalendarAPI.list_events_incremental(integration)
    end

    test "returns :gone when the stored token has expired" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
          google_sync_token: "stale_token"
        )

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 410, body: Jason.encode!(%{"error" => "Sync token expired"})}}
      end)

      assert {:error, :gone, _message} = CalendarAPI.list_events_incremental(integration)
    end
  end
end
