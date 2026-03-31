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

  describe "to_cache_attrs/2" do
    test "maps body.content as description" do
      event = %{
        "id" => "ev1",
        "iCalUId" => "ical-uid-1",
        "subject" => "Sync Meeting",
        "start" => %{"dateTime" => "2030-03-15T10:00:00", "timeZone" => "UTC"},
        "end" => %{"dateTime" => "2030-03-15T11:00:00", "timeZone" => "UTC"},
        "isAllDay" => false,
        "location" => %{"displayName" => "Conference Room A"},
        "body" => %{"contentType" => "text", "content" => "Full body notes here."},
        "attendees" => [],
        "showAs" => "busy"
      }

      attrs = CalendarAPI.to_cache_attrs(event, 42)

      assert attrs.description == "Full body notes here."
      assert attrs.location == "Conference Room A"
    end

    test "maps location displayName and nil body gracefully" do
      event = %{
        "id" => "ev2",
        "iCalUId" => "ical-uid-2",
        "subject" => "Quick Chat",
        "start" => %{"dateTime" => "2030-03-15T14:00:00", "timeZone" => "UTC"},
        "end" => %{"dateTime" => "2030-03-15T14:30:00", "timeZone" => "UTC"},
        "isAllDay" => false,
        "location" => %{"displayName" => ""},
        "attendees" => [],
        "showAs" => "free"
      }

      attrs = CalendarAPI.to_cache_attrs(event, 42)

      assert is_nil(attrs.description)
      assert attrs.status == "free"
    end

    test "maps attendees to consistent email/name/status format" do
      event = %{
        "id" => "ev3",
        "iCalUId" => "ical-uid-3",
        "subject" => "Standup",
        "start" => %{"dateTime" => "2030-03-15T09:00:00", "timeZone" => "UTC"},
        "end" => %{"dateTime" => "2030-03-15T09:15:00", "timeZone" => "UTC"},
        "isAllDay" => false,
        "attendees" => [
          %{
            "emailAddress" => %{"address" => "alice@example.com", "name" => "Alice"},
            "status" => %{"response" => "accepted"}
          },
          %{
            "emailAddress" => %{"address" => "bob@example.com", "name" => "Bob"},
            "status" => %{"response" => "tentativelyAccepted"}
          }
        ],
        "showAs" => "busy"
      }

      attrs = CalendarAPI.to_cache_attrs(event, 42)

      assert [alice, bob] = attrs.attendees
      assert alice["email"] == "alice@example.com"
      assert alice["name"] == "Alice"
      assert alice["status"] == "accepted"
      assert bob["email"] == "bob@example.com"
      assert bob["status"] == "tentativelyAccepted"
    end
  end

  describe "transient error handling" do
    test "returns network_error on transport failure" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
        )

      Tymeslot.HTTPClientMock
      |> expect(:request, fn :get, _url, _body, _headers, _opts ->
        {:error, %Mint.TransportError{reason: :timeout}}
      end)

      assert {:error, :network_error, _msg} = CalendarAPI.list_calendars(integration)
    end
  end
end
