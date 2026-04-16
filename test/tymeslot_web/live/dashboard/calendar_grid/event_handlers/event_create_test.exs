defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.EventCreateTest do
  @moduledoc """
  Unit tests for EventCreate — the dashboard calendar-grid create flow.

  These cover the new wiring that Task 13 introduced:

    * `handle_create_result/2` persists `video_integration_id` and description
      to the cache row, and flashes copy that reflects attendee presence.
    * `run_create_event/1` routes success notifications through
      `AttendeeNotifications.event_created/2`, and — when a video integration
      is selected — provisions a meeting room and surfaces its URL in the
      invitation email's description payload.

  The full provider-call path is stubbed: we fake `EventOperations.create_event`
  via `Tymeslot.CalendarMock` and the MiroTalk provider via `HTTPClientMock`.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Workers.EmailWorker
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.EventCreate

  setup :verify_on_exit!

  describe "handle_create_result/2" do
    test "flashes 'Event created.' when there are no attendees" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      result = build_result(integration, attendees: [])
      socket = build_socket()

      {:noreply, updated_socket} = EventCreate.handle_create_result({:ok, result}, socket)

      assert updated_socket.assigns.flash["info"] == "Event created."
    end

    test "flashes 'Event created. Attendees have been invited.' with attendees" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      result = build_result(integration, attendees: [%{email: "a@x.com"}])
      socket = build_socket()

      {:noreply, updated_socket} = EventCreate.handle_create_result({:ok, result}, socket)

      assert updated_socket.assigns.flash["info"] ==
               "Event created. Attendees have been invited."
    end

    test "persists video_integration_id and description on the cached event" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)
      video_integration = insert(:video_integration, user: user)

      result =
        build_result(integration,
          attendees: [%{email: "a@x.com"}],
          video_integration_id: video_integration.id,
          description: "Weekly sync\n\nJoin video call: https://meet.example.com/abc"
        )

      socket = build_socket()

      {:noreply, _socket} = EventCreate.handle_create_result({:ok, result}, socket)

      {:ok, cached} = CalendarGrid.get_cached_event(integration.id, result.uid)
      assert cached.description =~ "https://meet.example.com/abc"
      assert cached.description =~ "Weekly sync"
    end
  end

  describe "run_create_event/1 with a video integration" do
    test "provisions a room, embeds the URL in the description, and enqueues invitations" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      video_integration =
        insert(:video_integration, user: user, provider: "mirotalk")

      # Stub the MiroTalk provider's HTTP call to return a successful room.
      mirotalk_body =
        Jason.encode!(%{
          "room_id" => "room-123",
          "meeting_url" => "https://video.example.com/join/room-123"
        })

      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: mirotalk_body}}
      end)

      # Stub the calendar provider's create_event to return a UID directly.
      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        # Sanity check: the description reaching the provider now carries
        # the video link, so CalDAV servers propagate it to the ICS body.
        assert event_data.description =~ "https://video.example.com/join/room-123"
        {:ok, "new-uid-123"}
      end)

      start_at = ~U[2026-04-06 09:00:00Z]
      end_at = ~U[2026-04-06 09:30:00Z]

      payload = %{
        creating: %{
          title: "Team Sync",
          integration_id: integration.id,
          calendar_id: "primary",
          attendees: ["alice@example.com"],
          video_integration_id: video_integration.id
        },
        user_id: user.id,
        start_at: start_at,
        end_at: end_at
      }

      # Route EventCreate's provider call through the Mox-backed mock so
      # we don't need a real CalDAV server for the test.
      original =
        Application.get_env(:tymeslot, :event_create_operations_module)

      Application.put_env(
        :tymeslot,
        :event_create_operations_module,
        Tymeslot.CalendarMock
      )

      try do
        assert {:ok, result} = EventCreate.run_create_event(payload)

        assert result.meeting_url == "https://video.example.com/join/room-123"
        assert result.video_room_id == "room-123"
        assert result.description =~ "https://video.example.com/join/room-123"

        assert_enqueued(
          worker: EmailWorker,
          args: %{
            "action" => "send_calendar_invitation",
            "attendee_email" => "alice@example.com",
            "event_uid" => "new-uid-123"
          }
        )
      after
        if original do
          Application.put_env(:tymeslot, :event_create_operations_module, original)
        else
          Application.delete_env(:tymeslot, :event_create_operations_module)
        end
      end
    end
  end

  # Helpers

  defp build_result(integration, opts) do
    attendees = Keyword.get(opts, :attendees, [])
    video_integration_id = Keyword.get(opts, :video_integration_id, nil)
    description = Keyword.get(opts, :description, nil)

    %{
      uid: "uid-" <> Integer.to_string(System.unique_integer([:positive])),
      creating: %{
        title: "New Event",
        integration_id: integration.id,
        calendar_id: "primary",
        video_integration_id: video_integration_id
      },
      start_at: ~U[2026-04-06 09:00:00Z],
      end_at: ~U[2026-04-06 09:30:00Z],
      provider: integration.provider,
      default_booking_calendar_id: nil,
      attendees: attendees,
      meeting_url: nil,
      video_room_id: nil,
      description: description
    }
  end

  defp build_socket do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, flash: %{}}
    }
  end
end
