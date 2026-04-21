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

      assert {:ok, [%{"id" => "event1"}]} =
               CalendarAPI.list_events(integration, "test-cal", start_time, end_time)
    end
  end

  describe "create_event/2" do
    test "sends correct payload with fingerprint to primary calendar" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
        )

      event_data = %{
        summary: "Primary Calendar Meeting",
        start_time: DateTime.utc_now(),
        end_time: DateTime.add(DateTime.utc_now(), 3600),
        timezone: "UTC"
      }

      expect(Tymeslot.HTTPClientMock, :request, fn :post, url, body, _headers, _opts ->
        assert String.contains?(url, "/me/events")
        decoded_body = Jason.decode!(body)
        assert decoded_body["subject"] == "Primary Calendar Meeting"

        assert [%{"value" => "tymeslot"}] =
                 decoded_body["singleValueExtendedProperties"]

        {:ok,
         %Req.Response{
           status: 201,
           body:
             Jason.encode!(%{
               "id" => "new_primary_id",
               "subject" => "Primary Calendar Meeting",
               "start" => %{"dateTime" => "2024-01-01T10:00:00"},
               "end" => %{"dateTime" => "2024-01-01T11:00:00"}
             })
         }}
      end)

      assert {:ok, %{id: "new_primary_id"}} = CalendarAPI.create_event(integration, event_data)
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

        assert [%{"value" => "tymeslot"}] =
                 decoded_body["singleValueExtendedProperties"]

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

        assert [%{"value" => "tymeslot"}] =
                 decoded_body["singleValueExtendedProperties"]

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

      prior = Application.get_env(:tymeslot, :outlook_oauth)
      Application.put_env(:tymeslot, :outlook_oauth, client_id: "client", client_secret: "secret")

      on_exit(fn ->
        if prior,
          do: Application.put_env(:tymeslot, :outlook_oauth, prior),
          else: Application.delete_env(:tymeslot, :outlook_oauth)
      end)

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

  describe "convert_to_common_format/1" do
    test "maps all Graph API string-keyed fields to atom-keyed internal format" do
      raw_event = %{
        "id" => "AAMkAGI=",
        "iCalUId" => "040000008200E00074C5B7101A82E008",
        "subject" => "All-hands meeting",
        "body" => %{"content" => "Quarterly review", "contentType" => "text"},
        "location" => %{"displayName" => "Main Conference Room"},
        "start" => %{"dateTime" => "2024-03-15T14:00:00", "timeZone" => "UTC"},
        "end" => %{"dateTime" => "2024-03-15T15:00:00", "timeZone" => "UTC"},
        "isAllDay" => false,
        "isCancelled" => false,
        "showAs" => "busy",
        "sensitivity" => "normal",
        "responseStatus" => %{"response" => "accepted", "time" => "2024-03-01T08:00:00Z"},
        "organizer" => %{"emailAddress" => %{"name" => "Alice", "address" => "alice@example.com"}},
        "attendees" => [
          %{
            "emailAddress" => %{"name" => "Bob", "address" => "bob@example.com"},
            "status" => %{"response" => "accepted"}
          }
        ],
        "recurrence" => nil,
        "seriesMasterId" => nil
      }

      [result] = CalendarAPI.convert_to_common_format([raw_event])

      assert result.id == "AAMkAGI="
      assert result.summary == "All-hands meeting"
      assert result.description == "Quarterly review"
      assert result.location == "Main Conference Room"
      assert result.start == %{"dateTime" => "2024-03-15T14:00:00", "timeZone" => "UTC"}
      assert result.end == %{"dateTime" => "2024-03-15T15:00:00", "timeZone" => "UTC"}
      assert result.is_all_day == false
      assert result.status == "confirmed"
      assert result.show_as == "busy"
      assert result.response_status == "accepted"
    end

    test "maps isCancelled: true to status: cancelled" do
      raw_event = %{
        "id" => "evt-cancelled",
        "subject" => "Cancelled meeting",
        "body" => %{"content" => nil},
        "location" => %{"displayName" => nil},
        "start" => %{"dateTime" => "2024-03-15T14:00:00"},
        "end" => %{"dateTime" => "2024-03-15T15:00:00"},
        "isAllDay" => false,
        "isCancelled" => true,
        "showAs" => "free",
        "responseStatus" => %{"response" => "none"}
      }

      [result] = CalendarAPI.convert_to_common_format([raw_event])

      assert result.status == "cancelled"
    end

    test "defaults is_all_day to false when isAllDay is absent" do
      raw_event = %{
        "id" => "evt-no-allday",
        "subject" => "Quick sync",
        "body" => %{"content" => nil},
        "location" => %{"displayName" => nil},
        "start" => %{"dateTime" => "2024-03-15T14:00:00"},
        "end" => %{"dateTime" => "2024-03-15T15:00:00"},
        "isCancelled" => false,
        "showAs" => "busy",
        "responseStatus" => %{"response" => "accepted"}
      }

      [result] = CalendarAPI.convert_to_common_format([raw_event])

      assert result.is_all_day == false
    end

    test "handles missing optional fields gracefully" do
      raw_event = %{
        "id" => "evt-minimal",
        "isCancelled" => false
      }

      [result] = CalendarAPI.convert_to_common_format([raw_event])

      assert result.id == "evt-minimal"
      assert result.summary == nil
      assert result.description == nil
      assert result.location == nil
      assert result.start == nil
      assert result.end == nil
      assert result.is_all_day == false
      assert result.status == "confirmed"
      assert result.show_as == nil
      assert result.response_status == nil
    end

    test "converts multiple events in one call" do
      raw_events = [
        %{"id" => "evt-1", "isCancelled" => false, "subject" => "First"},
        %{"id" => "evt-2", "isCancelled" => true, "subject" => "Second"}
      ]

      results = CalendarAPI.convert_to_common_format(raw_events)

      assert length(results) == 2
      assert Enum.at(results, 0).id == "evt-1"
      assert Enum.at(results, 0).status == "confirmed"
      assert Enum.at(results, 1).id == "evt-2"
      assert Enum.at(results, 1).status == "cancelled"
    end

    test "returns empty list for empty input" do
      assert [] = CalendarAPI.convert_to_common_format([])
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

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:error, %Mint.TransportError{reason: :timeout}}
      end)

      assert {:error, :network_error, _msg} = CalendarAPI.list_calendars(integration)
    end
  end

  describe "error taxonomy" do
    # Outlook maps HTTP statuses to the same atoms as Google, except that
    # 429 has an explicit handler (Google routes its rate-limited signal
    # via 403 + a Graph-free "rateLimitExceeded" reason). Downstream
    # callers branch on the atom, so each code-to-atom edge needs a
    # regression.

    setup do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
        )

      %{integration: integration}
    end

    test "404 from Graph API surfaces as :not_found", %{integration: integration} do
      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: ""}}
      end)

      assert {:error, :not_found, _msg} = CalendarAPI.list_calendars(integration)
    end

    test "429 from Graph API surfaces as :rate_limited", %{integration: integration} do
      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 429, body: ""}}
      end)

      assert {:error, :rate_limited, _msg} = CalendarAPI.list_calendars(integration)
    end

    test "500 from Graph API surfaces as :network_error", %{integration: integration} do
      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 500, body: ""}}
      end)

      assert {:error, :network_error, _msg} = CalendarAPI.list_calendars(integration)
    end

    test "403 with a throttled Graph code surfaces as :rate_limited", %{
      integration: integration
    } do
      body =
        Jason.encode!(%{
          "error" => %{
            "code" => "ApplicationThrottled",
            "message" => "Application has been throttled"
          }
        })

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 403, body: body, headers: %{}}}
      end)

      assert {:error, :rate_limited, _msg} = CalendarAPI.list_calendars(integration)
    end

    test "403 with empty body surfaces as :network_error", %{integration: integration} do
      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 403, body: "", headers: %{}}}
      end)

      assert {:error, :network_error, _msg} = CalendarAPI.list_calendars(integration)
    end

    test "403 with AccessDenied code surfaces as :unauthorized", %{integration: integration} do
      body =
        Jason.encode!(%{
          "error" => %{
            "code" => "AccessDenied",
            "message" => "Insufficient privileges to complete the operation."
          }
        })

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 403, body: body, headers: %{}}}
      end)

      assert {:error, :unauthorized, _msg} = CalendarAPI.list_calendars(integration)
    end

    test "403 with Retry-After header includes retry_after seconds in message", %{
      integration: integration
    } do
      body =
        Jason.encode!(%{
          "error" => %{
            "code" => "ApplicationThrottled",
            "message" => "Application has been throttled"
          }
        })

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 403,
           body: body,
           headers: %{"retry-after" => ["120"]}
         }}
      end)

      assert {:error, :rate_limited, "retry_after:120"} = CalendarAPI.list_calendars(integration)
    end
  end
end
