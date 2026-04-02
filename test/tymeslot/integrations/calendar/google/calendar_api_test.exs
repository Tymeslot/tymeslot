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

  describe "refresh_token/1" do
    test "calls Google token endpoint and returns new tokens" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          refresh_token_encrypted: Encryption.encrypt("old_refresh_token")
        )

      Application.put_env(:tymeslot, :google_oauth, client_id: "client", client_secret: "secret")

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
end
