defmodule Tymeslot.Integrations.Video.Providers.TeamsProviderEventsTest do
  @moduledoc """
  The Graph event writes behind a Teams room: the new event a room of its own
  creates, the online meeting attached to the booking's own calendar event, and
  the later moves and deletions of a room's event.
  """

  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Shared.MicrosoftConfig
  alias Tymeslot.Integrations.Video.EventDetails
  alias Tymeslot.Integrations.Video.Providers.TeamsProvider
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Repo
  alias Tymeslot.TeamsOAuthHelperMock

  setup :verify_on_exit!

  @booking_start ~U[2030-03-14 09:30:00Z]
  @booking_end ~U[2030-03-14 10:15:00Z]

  # The event a room of its own writes is the one the organiser sees in their
  # calendar, so it must carry the booking's title and times (#144).
  describe "create_meeting_room/1 event body" do
    test "gives the new event the booking's subject, start and end in UTC" do
      config = valid_config()
      test_pid = self()

      expect(TeamsOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :post, url, body, _headers, _opts ->
        send(test_pid, {:posted, url, decode_request_body(body)})
        {:ok, %Req.Response{status: 201, body: Jason.encode!(teams_event("own-1"))}}
      end)

      assert {:ok, _room} = TeamsProvider.create_meeting_room(config)

      assert_received {:posted, "https://graph.microsoft.com/v1.0/me/events", body}
      assert body["subject"] == "Quarterly review"
      assert body["start"] == %{"dateTime" => "2030-03-14T09:30:00Z", "timeZone" => "UTC"}
      assert body["end"] == %{"dateTime" => "2030-03-14T10:15:00Z", "timeZone" => "UTC"}
      assert body["isOnlineMeeting"] == true
    end

    test "falls back to the flat meeting keys when no event details are attached" do
      config =
        valid_config()
        |> Map.delete(:event_details)
        |> Map.merge(%{
          meeting_topic: "Legacy topic",
          meeting_start_time: ~U[2030-05-01 12:00:00Z],
          meeting_end_time: ~U[2030-05-01 12:30:00Z]
        })

      test_pid = self()

      expect(TeamsOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :post, _url, body, _headers, _opts ->
        send(test_pid, {:posted, decode_request_body(body)})
        {:ok, %Req.Response{status: 201, body: Jason.encode!(teams_event("own-2"))}}
      end)

      assert {:ok, _room} = TeamsProvider.create_meeting_room(config)

      assert_received {:posted, body}
      assert body["subject"] == "Legacy topic"
      assert body["start"]["dateTime"] == "2030-05-01T12:00:00Z"
      assert body["end"]["dateTime"] == "2030-05-01T12:30:00Z"
    end

    test "refuses to write an event when the booking has no times" do
      # No HTTP expectation: any Graph call fails the test through Mox. An
      # event at a made-up time is the placeholder of #144.
      config = Map.put(valid_config(), :event_details, %EventDetails{summary: "No times"})

      expect(TeamsOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      assert {:error, {:configuration_error, "Teams meeting has no exact start_time"}} =
               TeamsProvider.create_meeting_room(config)
    end
  end

  # With the booking's own Outlook event known, the meeting is attached to it
  # instead of written as a second event (#145).
  describe "create_meeting_room/1 on the booking's calendar event" do
    test "patches only the online meeting onto the event and posts nothing" do
      config =
        Map.merge(valid_config(), %{
          calendar_event_id: "booking-event-1",
          tenant_id: "contoso-tenant"
        })

      test_pid = self()

      expect(TeamsOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      # `expect/4` with a `:patch` clause only: a POST or a DELETE would be an
      # unexpected call and fail the test.
      expect(HTTPClientMock, :request, fn :patch, url, body, _headers, _opts ->
        send(test_pid, {:patched, url, decode_request_body(body)})

        {:ok, %Req.Response{status: 200, body: Jason.encode!(teams_event("booking-event-1"))}}
      end)

      assert {:ok, room} = TeamsProvider.create_meeting_room(config)

      assert_received {:patched, url, body}
      assert url == "https://graph.microsoft.com/v1.0/me/events/booking-event-1"

      assert body == %{"isOnlineMeeting" => true, "onlineMeetingProvider" => "teamsForBusiness"}

      assert room.room_id == "booking-event-1"
      assert room.meeting_url == "https://teams.microsoft.com/l/meetup-join/booking-event-1"
    end

    test "leaves the provider to Graph for a personal Microsoft account" do
      config =
        Map.merge(valid_config(), %{
          calendar_event_id: "booking-event-2",
          tenant_id: MicrosoftConfig.consumer_tenant_id()
        })

      test_pid = self()

      expect(TeamsOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :patch, _url, body, _headers, _opts ->
        send(test_pid, {:patched, decode_request_body(body)})
        {:ok, %Req.Response{status: 200, body: Jason.encode!(teams_event("booking-event-2"))}}
      end)

      assert {:ok, _room} = TeamsProvider.create_meeting_room(config)

      assert_received {:patched, body}
      assert body == %{"isOnlineMeeting" => true}
    end

    test "never deletes the booking's event when it comes back without a join link" do
      config = Map.put(valid_config(), :calendar_event_id, "booking-event-3")

      expect(TeamsOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      # Exactly one call, the PATCH: a clean-up DELETE here would remove the
      # booking itself from the organiser's calendar.
      expect(HTTPClientMock, :request, 1, fn :patch, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => "booking-event-3"})}}
      end)

      assert {:error, :video_meeting_not_enabled} = TeamsProvider.create_meeting_room(config)
    end
  end

  describe "update_meeting_room/2" do
    test "moves the room's event to the new subject and times" do
      # The flat keys are what `Rooms.update_meeting_room/2` merges in.
      config =
        valid_config()
        |> Map.delete(:event_details)
        |> Map.merge(%{
          meeting_topic: "Moved review",
          meeting_start_time: ~U[2030-04-02 14:00:00Z],
          meeting_end_time: ~U[2030-04-02 15:00:00Z]
        })

      test_pid = self()

      expect(TeamsOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :patch, url, body, _headers, _opts ->
        send(test_pid, {:patched, url, decode_request_body(body)})
        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"id" => "room-event-1"})}}
      end)

      assert :ok = TeamsProvider.update_meeting_room("room-event-1", config)

      assert_received {:patched, url, body}
      assert url == "https://graph.microsoft.com/v1.0/me/events/room-event-1"

      assert body == %{
               "subject" => "Moved review",
               "start" => %{"dateTime" => "2030-04-02T14:00:00Z", "timeZone" => "UTC"},
               "end" => %{"dateTime" => "2030-04-02T15:00:00Z", "timeZone" => "UTC"}
             }
    end

    test "reports an event already gone as not found" do
      config = valid_config()

      expect(TeamsOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :patch, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 404,
           body: Jason.encode!(%{"error" => %{"code" => "ErrorItemNotFound"}})
         }}
      end)

      assert {:error, :meeting_not_found} = TeamsProvider.update_meeting_room("gone", config)
    end

    test "flags the integration as needs_reauth on a 401 from Graph" do
      {integration, config} = persisted_integration_config()

      expect(TeamsOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :patch, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 401,
           body: Jason.encode!(%{"error" => %{"code" => "InvalidAuthenticationToken"}})
         }}
      end)

      assert {:error, {:http_error, 401, _message}} =
               TeamsProvider.update_meeting_room("room-event-2", config)

      flagged = Repo.get(VideoIntegrationSchema, integration.id)
      assert flagged.needs_reauth == true
      assert flagged.sync_error =~ "reconnect"
    end

    test "refuses without Calendars.ReadWrite before any network call" do
      config = %{valid_config() | oauth_scope: "User.Read"}

      assert {:error, :invalid_configuration} =
               TeamsProvider.update_meeting_room("room-event-3", config)
    end
  end

  describe "delete_meeting_room/2" do
    test "deletes the room's event" do
      config = valid_config()
      test_pid = self()

      expect(TeamsOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :delete, url, _body, _headers, _opts ->
        send(test_pid, {:deleted, url})
        {:ok, %Req.Response{status: 204, body: ""}}
      end)

      assert :ok = TeamsProvider.delete_meeting_room("room-event-4", config)

      assert_received {:deleted, "https://graph.microsoft.com/v1.0/me/events/room-event-4"}
    end

    test "reports an event already gone as not found" do
      config = valid_config()

      expect(TeamsOAuthHelperMock, :validate_token, fn ^config -> {:ok, :valid} end)

      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 404, body: ""}}
      end)

      assert {:error, :meeting_not_found} = TeamsProvider.delete_meeting_room("gone", config)
    end
  end

  defp valid_config do
    with_booking(%{
      access_token: "valid_token",
      refresh_token: "refresh_token",
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      oauth_scope: "Calendars.ReadWrite"
    })
  end

  defp with_booking(config) do
    Map.put(config, :event_details, %EventDetails{
      summary: "Quarterly review",
      start_time: @booking_start,
      end_time: @booking_end
    })
  end

  defp decode_request_body(body), do: Jason.decode!(body)

  # A Graph event carrying a Teams join link.
  defp teams_event(id),
    do: %{
      "id" => id,
      "onlineMeeting" => %{"joinUrl" => "https://teams.microsoft.com/l/meetup-join/#{id}"}
    }

  defp persisted_integration_config do
    user = insert(:user)

    {:ok, integration} =
      VideoIntegrationQueries.create(%{
        user_id: user.id,
        name: "Teams",
        provider: "teams",
        tenant_id: "t1",
        teams_user_id: "u1",
        access_token: "valid_token",
        refresh_token: "refresh_token",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        oauth_scope: "Calendars.ReadWrite"
      })

    config = Map.merge(valid_config(), %{integration_id: integration.id, user_id: user.id})
    {integration, config}
  end
end
