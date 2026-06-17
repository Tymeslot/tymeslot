defmodule Tymeslot.Integrations.Video.Providers.GoogleMeetProviderCreateRoomTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.GoogleOAuthHelperMock
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video.Providers.GoogleMeetProvider
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Repo

  setup :verify_on_exit!

  describe "create_meeting_room/1" do
    test "successfully creates a meeting room" do
      config = %{
        access_token: "valid_token",
        refresh_token: "refresh_token",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      event_response = %{
        "id" => "event123",
        "conferenceData" => %{
          "entryPoints" => [
            %{"entryPointType" => "video", "uri" => "https://meet.google.com/abc-defg-hij"}
          ]
        }
      }

      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: Jason.encode!(event_response)}}
      end)

      assert {:ok, room_data} = GoogleMeetProvider.create_meeting_room(config)
      assert room_data.room_id == "abc-defg-hij"
      assert room_data.meeting_url == "https://meet.google.com/abc-defg-hij"
    end

    test "returns error when API response is malformed JSON" do
      config = valid_token_config()

      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "not valid json{{"}}
      end)

      assert {:error, message} = GoogleMeetProvider.create_meeting_room(config)
      assert message =~ "Invalid JSON"
    end

    test "returns error when conference data is missing" do
      config = valid_token_config()

      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => "event123"})}}
      end)

      assert {:error, message} = GoogleMeetProvider.create_meeting_room(config)
      assert String.contains?(message, "did not return conference data")
    end

    test "handles malformed or unexpected conference data structure" do
      config = valid_token_config()

      # Case 1: entryPoints is not a list
      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: Jason.encode!(%{"conferenceData" => %{"entryPoints" => "not_a_list"}})
         }}
      end)

      assert {:error, "Google Calendar did not return conference data"} =
               GoogleMeetProvider.create_meeting_room(config)

      # Case 2: entryPoints is empty list
      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: Jason.encode!(%{"conferenceData" => %{"entryPoints" => []}})
         }}
      end)

      assert {:error, "No meeting URL returned from Google"} =
               GoogleMeetProvider.create_meeting_room(config)

      # Case 3: entryPoints lacks video type
      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "conferenceData" => %{
                 "entryPoints" => [%{"entryPointType" => "phone", "uri" => "tel:+123"}]
               }
             })
         }}
      end)

      assert {:error, "No meeting URL returned from Google"} =
               GoogleMeetProvider.create_meeting_room(config)
    end

    test "uses :event_details summary/times/attendees in the Calendar API write" do
      start_time = ~U[2026-06-01 09:00:00Z]
      end_time = ~U[2026-06-01 10:00:00Z]

      config =
        Map.put(valid_token_config(), :event_details, %{
          summary: "Quarterly Review",
          description: "Plan Q3",
          start_time: start_time,
          end_time: end_time,
          attendees: [%{email: "alice@example.com"}, "bob@example.com"]
        })

      event_response = %{
        "conferenceData" => %{
          "entryPoints" => [
            %{"entryPointType" => "video", "uri" => "https://meet.google.com/xyz-pqrs-uvw"}
          ]
        }
      }

      expect(HTTPClientMock, :request, fn :post, _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)

        assert decoded["summary"] == "Quarterly Review"
        assert decoded["description"] == "Plan Q3"
        assert decoded["start"]["dateTime"] == DateTime.to_iso8601(start_time)
        assert decoded["end"]["dateTime"] == DateTime.to_iso8601(end_time)

        assert Enum.sort(Enum.map(decoded["attendees"], & &1["email"])) ==
                 ["alice@example.com", "bob@example.com"]

        {:ok, %Req.Response{status: 200, body: Jason.encode!(event_response)}}
      end)

      assert {:ok, _room} = GoogleMeetProvider.create_meeting_room(config)
    end

    test "falls back to placeholder summary and stub times when :event_details is absent" do
      config = valid_token_config()

      event_response = %{
        "conferenceData" => %{
          "entryPoints" => [
            %{"entryPointType" => "video", "uri" => "https://meet.google.com/qaz-wsx-edc"}
          ]
        }
      }

      expect(HTTPClientMock, :request, fn :post, _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)

        assert decoded["summary"] == "Tymeslot - Temporary Event for Google Meet"
        assert decoded["attendees"] == []

        {:ok, %Req.Response{status: 200, body: Jason.encode!(event_response)}}
      end)

      assert {:ok, _room} = GoogleMeetProvider.create_meeting_room(config)
    end

    test "persists refreshed tokens to database" do
      user = insert(:user)
      expires_at = DateTime.add(DateTime.utc_now(), -3600, :second)
      new_expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)

      integration =
        insert(:video_integration,
          user: user,
          provider: "google_meet",
          access_token: "expired",
          refresh_token: "refresh",
          token_expires_at: expires_at
        )

      config = %{
        access_token: "expired",
        refresh_token: "refresh",
        token_expires_at: expires_at,
        integration_id: integration.id,
        user_id: user.id
      }

      expect(GoogleOAuthHelperMock, :refresh_access_token, fn "refresh", nil ->
        {:ok,
         %{
           access_token: "new_token",
           refresh_token: "new_refresh",
           expires_at: new_expires_at,
           scope: "new_scope"
         }}
      end)

      expect(HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "conferenceData" => %{
                 "entryPoints" => [
                   %{"entryPointType" => "video", "uri" => "https://meet.google.com/abc-defg-hij"}
                 ]
               }
             })
         }}
      end)

      assert {:ok, _result} = GoogleMeetProvider.create_meeting_room(config)

      # Verify DB update
      updated = Repo.get(VideoIntegrationSchema, integration.id)
      decrypted = VideoIntegrationSchema.decrypt_credentials(updated)
      assert decrypted.access_token == "new_token"
      assert decrypted.refresh_token == "new_refresh"
      assert updated.oauth_scope == "new_scope"
    end

    test "skips refresh and uses fresh DB token when token already refreshed concurrently" do
      user = insert(:user)
      fresh_expiry = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, integration} =
        VideoIntegrationQueries.create(%{
          user_id: user.id,
          name: "Google Meet",
          provider: "google_meet",
          access_token: "fresh-token-from-other-process",
          refresh_token: "fresh-refresh-from-other-process",
          token_expires_at: fresh_expiry,
          oauth_scope: "calendar.scope"
        })

      config = %{
        access_token: "stale-token-current-process",
        refresh_token: "stale-refresh",
        token_expires_at: DateTime.add(DateTime.utc_now(), -10, :second),
        oauth_scope: "calendar.scope",
        integration_id: integration.id,
        user_id: user.id
      }

      # No refresh_access_token expectation: another process already refreshed
      # while we waited on the lock, so the merged config must carry the fresh
      # DB token and the HTTP call must use it.
      expect(HTTPClientMock, :request, fn :post, _url, _body, headers, _opts ->
        assert {"Authorization", "Bearer fresh-token-from-other-process"} in headers

        {:ok,
         %Req.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "conferenceData" => %{
                 "entryPoints" => [
                   %{"entryPointType" => "video", "uri" => "https://meet.google.com/abc-defg-hij"}
                 ]
               }
             })
         }}
      end)

      assert {:ok, _room} = GoogleMeetProvider.create_meeting_room(config)
    end
  end

  defp valid_token_config do
    %{
      access_token: "valid_token",
      refresh_token: "refresh_token",
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    }
  end
end
