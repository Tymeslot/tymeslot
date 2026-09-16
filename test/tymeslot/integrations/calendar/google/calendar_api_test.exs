defmodule Tymeslot.Integrations.Calendar.Google.CalendarAPITest do
  # async: false: :google_oauth is read by the OAuth helpers and by OAuthStateGuard on the
  # web path, both reachable from other tests.
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  import Tymeslot.Factory
  import Mox

  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI
  alias Tymeslot.Security.Encryption
  alias TymeslotWeb.Endpoint

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
                 "url" => Endpoint.url()
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

    test "returns Meet URL immediately when entryPoints are populated in the create response" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
        )

      event_data = %{
        summary: "Meet sync",
        start_time: ~U[2026-05-01 10:00:00Z],
        end_time: ~U[2026-05-01 11:00:00Z],
        conference_data: %{
          createRequest: %{requestId: "req1", conferenceSolutionKey: %{type: "hangoutsMeet"}}
        }
      }

      # Only one HTTP request — no follow-up GET needed
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "id" => "event-abc",
               "conferenceData" => %{
                 "entryPoints" => [
                   %{"entryPointType" => "video", "uri" => "https://meet.google.com/abc-defg"}
                 ]
               }
             })
         }}
      end)

      assert {:ok, response} = CalendarAPI.create_event(integration, "primary", event_data)

      assert get_in(response, ["conferenceData", "entryPoints"]) == [
               %{"entryPointType" => "video", "uri" => "https://meet.google.com/abc-defg"}
             ]
    end

    test "issues a follow-up GET when createRequest is pending and returns populated entryPoints" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
        )

      event_data = %{
        summary: "Pending Meet sync",
        start_time: ~U[2026-05-01 10:00:00Z],
        end_time: ~U[2026-05-01 11:00:00Z],
        conference_data: %{
          createRequest: %{requestId: "req2", conferenceSolutionKey: %{type: "hangoutsMeet"}}
        }
      }

      pending_body =
        Jason.encode!(%{
          "id" => "event-pending",
          "conferenceData" => %{
            "createRequest" => %{
              "requestId" => "req2",
              "status" => %{"statusCode" => "pending"}
            }
          }
        })

      resolved_body =
        Jason.encode!(%{
          "id" => "event-pending",
          "conferenceData" => %{
            "createRequest" => %{
              "requestId" => "req2",
              "status" => %{"statusCode" => "success"}
            },
            "entryPoints" => [
              %{"entryPointType" => "video", "uri" => "https://meet.google.com/pending-resolved"}
            ]
          }
        })

      # POST returns pending; follow-up GET returns resolved — two HTTP calls total
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: pending_body}}
      end)

      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: resolved_body}}
      end)

      assert {:ok, response} = CalendarAPI.create_event(integration, "primary", event_data)

      assert get_in(response, ["conferenceData", "entryPoints"]) == [
               %{
                 "entryPointType" => "video",
                 "uri" => "https://meet.google.com/pending-resolved"
               }
             ]
    end

    test "returns the original pending response when follow-up GET is still pending" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
        )

      event_data = %{
        summary: "Still pending Meet",
        start_time: ~U[2026-05-01 10:00:00Z],
        end_time: ~U[2026-05-01 11:00:00Z],
        conference_data: %{
          createRequest: %{requestId: "req3", conferenceSolutionKey: %{type: "hangoutsMeet"}}
        }
      }

      still_pending_body =
        Jason.encode!(%{
          "id" => "event-still-pending",
          "conferenceData" => %{
            "createRequest" => %{
              "requestId" => "req3",
              "status" => %{"statusCode" => "pending"}
            }
          }
        })

      # Both POST and follow-up GET return the pending state
      expect(Tymeslot.HTTPClientMock, :request, 2, fn _method, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: still_pending_body}}
      end)

      assert {:ok, response} = CalendarAPI.create_event(integration, "primary", event_data)
      # entryPoints absent — finalise/3 will surface :no_meet_url
      assert is_nil(get_in(response, ["conferenceData", "entryPoints"]))
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
                 "url" => Endpoint.url()
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

  describe "refresh_token/1" do
    setup do
      prior = Application.get_env(:tymeslot, :google_oauth)
      Application.put_env(:tymeslot, :google_oauth, client_id: "client", client_secret: "secret")

      on_exit(fn ->
        if prior,
          do: Application.put_env(:tymeslot, :google_oauth, prior),
          else: Application.delete_env(:tymeslot, :google_oauth)
      end)

      integration =
        insert(:calendar_integration,
          user: insert(:user),
          provider: "google",
          refresh_token_encrypted: Encryption.encrypt("old_refresh_token")
        )

      %{integration: integration}
    end

    test "calls Google token endpoint and returns new tokens", %{integration: integration} do
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

    # The body is where the OAuth error code lives; the health check can only
    # tell a revoked grant from other refusals if the code survives into the
    # message.
    test "keeps the OAuth error code from a 400 response in the message", %{
      integration: integration
    } do
      expect(Tymeslot.HTTPClientMock, :request, fn :post,
                                                   "https://oauth2.googleapis.com/token",
                                                   _body,
                                                   _headers,
                                                   _opts ->
        {:ok, %Req.Response{status: 400, body: ~s({"error":"invalid_grant"})}}
      end)

      assert {:error, :unauthorized, "Token refresh failed: invalid_grant"} =
               CalendarAPI.refresh_token(integration)
    end

    # Google answers a rejected client registration with a 401, not a 400.
    # Reported as a network error it would be retried eight times and the
    # owner never told.
    test "keeps the OAuth error code from a 401 response in the message", %{
      integration: integration
    } do
      expect(Tymeslot.HTTPClientMock, :request, fn :post,
                                                   "https://oauth2.googleapis.com/token",
                                                   _body,
                                                   _headers,
                                                   _opts ->
        {:ok, %Req.Response{status: 401, body: ~s({"error":"invalid_client"})}}
      end)

      assert {:error, :unauthorized, "Token refresh failed: invalid_client"} =
               CalendarAPI.refresh_token(integration)
    end
  end
end
