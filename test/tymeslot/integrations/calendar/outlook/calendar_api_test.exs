defmodule Tymeslot.Integrations.Calendar.Outlook.CalendarAPITest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import Tymeslot.Factory
  import Mox

  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  describe "list_calendars/1" do
    test "returns list of calendars when successful" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
        )

      expect(Tymeslot.HTTPClientMock, :request, fn :get, url, _body, headers, _opts ->
        assert String.starts_with?(url, "https://graph.microsoft.com/v1.0/me/calendars")

        assert Enum.any?(headers, fn {k, v} ->
                 String.downcase(k) == "authorization" and v == "Bearer valid_token"
               end)

        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "value" => [%{"id" => "cal1", "name" => "Work Calendar"}]
             })
         }}
      end)

      assert {:ok, [%{"id" => "cal1"}]} = CalendarAPI.list_calendars(integration)
    end
  end

  describe "list_events/4" do
    test "fetches events for a specific calendar and date range" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
        )

      start_time = DateTime.utc_now()
      end_time = DateTime.add(start_time, 3600)

      expect(Tymeslot.HTTPClientMock, :request, fn :get, url, _body, headers, _opts ->
        assert String.contains?(url, "/me/calendars/test-cal/calendarView")
        assert String.contains?(url, "startDateTime=")
        assert String.contains?(url, "endDateTime=")

        assert Enum.any?(headers, fn {k, v} ->
                 String.downcase(k) == "prefer" and
                   String.contains?(v, "outlook.timezone=\"UTC\"")
               end)

        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "value" => [
                 %{
                   "id" => "event1",
                   "subject" => "Meeting",
                   "isCancelled" => false,
                   "start" => %{"dateTime" => "2024-01-01T10:00:00"},
                   "end" => %{"dateTime" => "2024-01-01T11:00:00"}
                 }
               ]
             })
         }}
      end)

      assert {:ok, [%{id: "event1"}]} =
               CalendarAPI.list_events(integration, "test-cal", start_time, end_time)
    end
  end

  describe "create_event/3" do
    test "sends correct payload to Outlook API" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
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
        assert String.contains?(url, "/me/calendars/primary/events")
        decoded_body = Jason.decode!(body)
        assert decoded_body["subject"] == "New Meeting"

        {:ok,
         %Req.Response{
           status: 201,
           body:
             Jason.encode!(%{
               "id" => "new_outlook_id",
               "subject" => "New Meeting",
               "start" => %{"dateTime" => "2024-01-01T10:00:00"},
               "end" => %{"dateTime" => "2024-01-01T11:00:00"}
             })
         }}
      end)

      assert {:ok, %{id: "new_outlook_id"}} =
               CalendarAPI.create_event(integration, "primary", event_data)
    end
  end

  describe "update_event/4" do
    test "sends PATCH request to Outlook API" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
        )

      event_data = %{summary: "Updated Meeting"}

      expect(Tymeslot.HTTPClientMock, :request, fn :patch, url, body, _headers, _opts ->
        assert String.contains?(url, "/me/calendars/primary/events/event123")
        decoded_body = Jason.decode!(body)
        assert decoded_body["subject"] == "Updated Meeting"

        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "id" => "event123",
               "subject" => "Updated Meeting",
               "start" => %{"dateTime" => "2024-01-01T10:00:00"},
               "end" => %{"dateTime" => "2024-01-01T11:00:00"}
             })
         }}
      end)

      assert {:ok, %{id: "event123"}} =
               CalendarAPI.update_event(integration, "primary", "event123", event_data)
    end
  end

  describe "delete_event/3" do
    test "sends DELETE request to Outlook API" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
        )

      expect(Tymeslot.HTTPClientMock, :request, fn :delete, url, _body, _headers, _opts ->
        assert String.contains?(url, "/me/calendars/primary/events/event123")

        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert :ok = CalendarAPI.delete_event(integration, "primary", "event123")
    end
  end

  describe "refresh_token/1" do
    test "calls Microsoft token endpoint and returns new tokens" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          refresh_token_encrypted: Encryption.encrypt("old_refresh_token")
        )

      Application.put_env(:tymeslot, :outlook_oauth, client_id: "client", client_secret: "secret")

      expect(Tymeslot.HTTPClientMock, :request, fn :post, url, body, _headers, _opts ->
        assert url == "https://login.microsoftonline.com/common/oauth2/v2.0/token"
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

  describe "retry logic" do
    test "retries on transient errors" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
        )

      # Expect 2 calls: first fails with timeout, second succeeds
      Tymeslot.HTTPClientMock
      |> expect(:request, fn :get, _url, _body, _headers, _opts ->
        {:error, %Mint.TransportError{reason: :timeout}}
      end)
      |> expect(:request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"value" => []})}}
      end)

      # We need to reduce the retry delay for tests to run fast
      # But Retry doesn't take opts in with_access_token call chain easily without modifying code
      # However, we can just assert it succeeds eventually
      assert {:ok, []} = CalendarAPI.list_calendars(integration)
    end
  end
end
