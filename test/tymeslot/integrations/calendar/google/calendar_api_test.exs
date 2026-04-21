defmodule Tymeslot.Integrations.Calendar.Google.CalendarAPITest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import Tymeslot.Factory
  import Mox

  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  describe "list_calendars/1" do
    test "returns list of calendars when successful" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
        )

      expect(Tymeslot.HTTPClientMock, :request, fn :get, url, _body, headers, _opts ->
        assert url == "https://www.googleapis.com/calendar/v3/users/me/calendarList"

        assert Enum.any?(headers, fn {k, v} ->
                 String.downcase(k) == "authorization" and v == "Bearer valid_token"
               end)

        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "items" => [%{"id" => "primary", "summary" => "Primary Calendar"}]
             })
         }}
      end)

      assert {:ok, [%{"id" => "primary"}]} = CalendarAPI.list_calendars(integration)
    end

    test "handles unauthorized error and returns error atom" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token_encrypted: Encryption.encrypt("expired_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
        )

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 401}}
      end)

      assert {:error, :unauthorized, _message} = CalendarAPI.list_calendars(integration)
    end
  end

  describe "list_events/4" do
    test "fetches events for a specific calendar and date range" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
        )

      start_time = DateTime.utc_now()
      end_time = DateTime.add(start_time, 3600)

      expect(Tymeslot.HTTPClientMock, :request, fn :get, url, _body, _headers, _opts ->
        assert String.starts_with?(
                 url,
                 "https://www.googleapis.com/calendar/v3/calendars/test-cal/events"
               )

        assert String.contains?(
                 url,
                 "timeMin=" <> URI.encode_www_form(DateTime.to_iso8601(start_time))
               )

        assert String.contains?(
                 url,
                 "timeMax=" <> URI.encode_www_form(DateTime.to_iso8601(end_time))
               )

        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "items" => [%{"id" => "event1", "summary" => "Meeting"}]
             })
         }}
      end)

      assert {:ok, [%{"id" => "event1"}]} =
               CalendarAPI.list_events(integration, "test-cal", start_time, end_time)
    end
  end

  describe "create_event/3" do
    test "sends correct payload to Google API" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
        )

      event_data = %{
        summary: "New Meeting",
        start_time: DateTime.utc_now(),
        end_time: DateTime.add(DateTime.utc_now(), 3600),
        timezone: "UTC"
      }

      expect(Tymeslot.HTTPClientMock, :request, fn :post, url, body, _headers, _opts ->
        assert url ==
                 "https://www.googleapis.com/calendar/v3/calendars/primary/events?sendUpdates=none"

        decoded_body = Jason.decode!(body)
        assert decoded_body["summary"] == "New Meeting"

        assert decoded_body["source"] == %{
                 "title" => "Tymeslot",
                 "url" => "https://tymeslot.app"
               }

        assert decoded_body["extendedProperties"] == %{
                 "private" => %{"createdBy" => "tymeslot"}
               }

        {:ok,
         %Req.Response{
           status: 200,
           body: Jason.encode!(%{"id" => "new_google_id"})
         }}
      end)

      assert {:ok, %{"id" => "new_google_id"}} =
               CalendarAPI.create_event(integration, "primary", event_data)
    end
  end

  describe "update_event/4" do
    test "PUT body includes extendedProperties and source fingerprint" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
        )

      event_data = %{
        summary: "Updated Meeting",
        start_time: DateTime.utc_now(),
        end_time: DateTime.add(DateTime.utc_now(), 3600),
        timezone: "UTC"
      }

      expect(Tymeslot.HTTPClientMock, :request, fn :put, url, body, _headers, _opts ->
        assert String.contains?(url, "/calendars/primary/events/")
        decoded_body = Jason.decode!(body)
        assert decoded_body["summary"] == "Updated Meeting"

        assert decoded_body["source"] == %{
                 "title" => "Tymeslot",
                 "url" => "https://tymeslot.app"
               }

        assert decoded_body["extendedProperties"] == %{
                 "private" => %{"createdBy" => "tymeslot"}
               }

        {:ok,
         %Req.Response{
           status: 200,
           body: Jason.encode!(%{"id" => "event-abc"})
         }}
      end)

      assert {:ok, %{"id" => "event-abc"}} =
               CalendarAPI.update_event(integration, "primary", "event-abc", event_data)
    end
  end

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

  describe "refresh_token/1" do
    test "calls Google token endpoint and returns new tokens" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          refresh_token_encrypted: Encryption.encrypt("old_refresh_token")
        )

      prior = Application.get_env(:tymeslot, :google_oauth)
      Application.put_env(:tymeslot, :google_oauth, client_id: "client", client_secret: "secret")

      on_exit(fn ->
        if prior,
          do: Application.put_env(:tymeslot, :google_oauth, prior),
          else: Application.delete_env(:tymeslot, :google_oauth)
      end)

      expect(Tymeslot.HTTPClientMock, :request, fn :post, url, body, _headers, _opts ->
        assert url == "https://oauth2.googleapis.com/token"
        assert String.contains?(body, "grant_type=refresh_token")
        assert String.contains?(body, "refresh_token=old_refresh_token")

        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "access_token" => "new_access_token",
               "refresh_token" => "new_refresh_token",
               "expires_in" => 3600
             })
         }}
      end)

      assert {:ok, {"new_access_token", "new_refresh_token", %DateTime{}}} =
               CalendarAPI.refresh_token(integration)
    end
  end

  describe "error taxonomy" do
    # Callers downstream of CalendarAPI (CalendarEventWorker, CircuitBreaker,
    # retry policies) route on the second element of the error tuple. These
    # tests lock in the contract that each HTTP status maps to a
    # distinguishable atom so those call sites keep working.

    setup do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
        )

      %{integration: integration}
    end

    test "404 from the Google API surfaces as :not_found", %{integration: integration} do
      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: ""}}
      end)

      assert {:error, :not_found, _msg} = CalendarAPI.list_calendars(integration)
    end

    test "500 from the Google API surfaces as :network_error", %{integration: integration} do
      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 500, body: ""}}
      end)

      assert {:error, :network_error, _msg} = CalendarAPI.list_calendars(integration)
    end

    test "403 with rateLimitExceeded reason surfaces as :rate_limited", %{
      integration: integration
    } do
      body =
        Jason.encode!(%{
          "error" => %{
            "message" => "Rate Limit Exceeded",
            "errors" => [%{"reason" => "rateLimitExceeded"}]
          }
        })

      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 403, body: body}}
      end)

      assert {:error, :rate_limited, _msg} =
               CalendarAPI.create_event(integration, "primary", %{
                 summary: "Team sync",
                 start_time: ~U[2026-05-01 10:00:00Z],
                 end_time: ~U[2026-05-01 11:00:00Z]
               })
    end

    test "a transport timeout surfaces as :network_error", %{integration: integration} do
      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:error, %Mint.TransportError{reason: :timeout}}
      end)

      assert {:error, :network_error, _msg} = CalendarAPI.list_calendars(integration)
    end
  end
end
