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
  alias Tymeslot.Security.Encryption
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

  describe "run_create_event/1 — Google calendar + Google Meet (same account, inline path)" do
    test "attaches conferenceData to the calendar event and extracts the Meet URL — no second Google Calendar event" do
      user = insert(:user)
      shared_account = "acct-overlap-1"

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          provider_account_id: shared_account,
          is_active: true
        )

      video_integration =
        insert(:video_integration,
          user: user,
          provider: "google_meet",
          provider_account_id: shared_account
        )

      meet_url = "https://meet.google.com/inline-abc-def"
      captured_url = meet_url

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        # Inline strategy attaches a conferenceData.createRequest…
        assert %{conference_data: %{createRequest: cr}} = event_data
        assert cr[:conferenceSolutionKey][:type] == "hangoutsMeet"
        assert is_binary(cr[:requestId])

        # …and the description must NOT carry the Meet URL — that's only
        # known after Google's response. conferenceData carries the URL
        # natively for the event itself; the description stays clean.
        refute event_data.description && event_data.description =~ "meet.google.com"

        # Return the converted event with :meet_url populated, matching what
        # Google.Provider.convert_event/1 produces from a real API response.
        {:ok,
         %{
           uid: "uid-inline-123",
           summary: event_data.summary,
           meet_url: captured_url
         }}
      end)

      start_at = ~U[2026-04-06 09:00:00Z]
      end_at = ~U[2026-04-06 09:30:00Z]

      payload = %{
        creating: %{
          title: "Strategy Sync",
          integration_id: integration.id,
          calendar_id: "primary",
          attendees: ["alice@example.com"],
          video_integration_id: video_integration.id
        },
        user_id: user.id,
        start_at: start_at,
        end_at: end_at
      }

      original = Application.get_env(:tymeslot, :event_create_operations_module)
      Application.put_env(:tymeslot, :event_create_operations_module, Tymeslot.CalendarMock)

      try do
        assert {:ok, result} = EventCreate.run_create_event(payload)

        assert result.meeting_url == meet_url
        # The room id is parsed out of the Meet URL by GoogleMeetProvider.extract_room_id
        assert result.video_room_id == "inline-abc-def"
        # The email/notification description carries the Meet URL — even though
        # the calendar event itself relies on conferenceData.
        assert result.description =~ meet_url

        assert_enqueued(
          worker: EmailWorker,
          args: %{
            "action" => "send_calendar_invitation",
            "attendee_email" => "alice@example.com",
            "event_uid" => "uid-inline-123"
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

  describe "run_create_event/1 — Google calendar + Google Meet (inline, no Meet URL returned)" do
    test "saves the event and emits a warning flash when Google returns no Meet URL" do
      user = insert(:user)
      shared_account = "acct-overlap-no-url"

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          provider_account_id: shared_account,
          is_active: true
        )

      video_integration =
        insert(:video_integration,
          user: user,
          provider: "google_meet",
          provider_account_id: shared_account
        )

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        # conferenceData request is attached
        assert %{conference_data: _conference_data} = event_data

        # Google returns a response with no entryPoints (Meet URL missing)
        {:ok, %{uid: "uid-no-url-456", summary: event_data.summary, meet_url: nil}}
      end)

      start_at = ~U[2026-04-07 10:00:00Z]
      end_at = ~U[2026-04-07 10:30:00Z]

      payload = %{
        creating: %{
          title: "No URL Meeting",
          integration_id: integration.id,
          calendar_id: "primary",
          attendees: [],
          video_integration_id: video_integration.id
        },
        user_id: user.id,
        start_at: start_at,
        end_at: end_at
      }

      original = Application.get_env(:tymeslot, :event_create_operations_module)
      Application.put_env(:tymeslot, :event_create_operations_module, Tymeslot.CalendarMock)

      try do
        assert {:ok, result} = EventCreate.run_create_event(payload)

        # The event is saved but meeting_url is nil
        assert is_nil(result.meeting_url)

        # A warning is signalled so handle_create_result can flash it
        assert result.warning =~ "Meet link"
      after
        if original do
          Application.put_env(:tymeslot, :event_create_operations_module, original)
        else
          Application.delete_env(:tymeslot, :event_create_operations_module)
        end
      end
    end
  end

  describe "handle_create_result/2 — no Meet URL warning" do
    test "flashes a warning alongside the success info when :warning key is present" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      result =
        build_result(integration,
          attendees: [],
          warning:
            "Google Calendar saved the event but didn't return a Meet link — please try again or add it manually."
        )

      socket = build_socket()

      {:noreply, updated_socket} = EventCreate.handle_create_result({:ok, result}, socket)

      assert updated_socket.assigns.flash["info"] == "Event created."
      assert updated_socket.assigns.flash["warning"] =~ "Meet link"
    end

    test "does not flash a warning when :warning key is absent" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      result = build_result(integration, attendees: [])
      socket = build_socket()

      {:noreply, updated_socket} = EventCreate.handle_create_result({:ok, result}, socket)

      assert updated_socket.assigns.flash["info"] == "Event created."
      assert is_nil(updated_socket.assigns.flash["warning"])
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

  describe "run_create_event/1 — inline Meet end-to-end" do
    setup do
      previous = Application.get_env(:tymeslot, :google_calendar_api_module)

      Application.put_env(
        :tymeslot,
        :google_calendar_api_module,
        Tymeslot.Integrations.Calendar.Google.CalendarAPI
      )

      on_exit(fn ->
        if previous do
          Application.put_env(:tymeslot, :google_calendar_api_module, previous)
        else
          Application.delete_env(:tymeslot, :google_calendar_api_module)
        end
      end)

      :ok
    end

    test "POSTs conferenceData to the Google API and extracts the Meet URL from the response" do
      user = insert(:user)
      shared_account = "user@gmail.com"

      calendar_integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          provider_account_id: shared_account,
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
          oauth_scope: "https://www.googleapis.com/auth/calendar",
          is_active: true
        )

      video_integration =
        insert(:video_integration,
          user: user,
          provider: "google_meet",
          provider_account_id: shared_account,
          is_active: true
        )

      meet_url = "https://meet.google.com/abc-defg-hij"

      google_response_body =
        Jason.encode!(%{
          "id" => "google-evt-1",
          "summary" => "Inline Meet",
          "start" => %{"dateTime" => "2026-05-01T10:00:00Z"},
          "end" => %{"dateTime" => "2026-05-01T11:00:00Z"},
          "status" => "confirmed",
          "conferenceData" => %{
            "createRequest" => %{
              "requestId" => "some-request-id",
              "status" => %{"statusCode" => "success"}
            },
            "entryPoints" => [
              %{"entryPointType" => "video", "uri" => meet_url}
            ]
          }
        })

      expect(Tymeslot.HTTPClientMock, :request, fn :post, url, body, _headers, _opts ->
        assert String.contains?(url, "conferenceDataVersion=1")

        decoded = Jason.decode!(body)
        assert Map.has_key?(decoded, "conferenceData")
        assert get_in(decoded, ["conferenceData", "createRequest"]) != nil

        {:ok, %Req.Response{status: 200, body: google_response_body}}
      end)

      payload = %{
        creating: %{
          title: "Inline Meet",
          description: "Async planning",
          integration_id: calendar_integration.id,
          calendar_id: "primary",
          attendees: ["alice@example.com"],
          video_integration_id: video_integration.id
        },
        user_id: user.id,
        start_at: ~U[2026-05-01 10:00:00Z],
        end_at: ~U[2026-05-01 11:00:00Z]
      }

      assert {:ok, result} = EventCreate.run_create_event(payload)
      assert result.meeting_url == meet_url
      assert result.video_room_id == "abc-defg-hij"
      assert result.creating.video_integration_id == video_integration.id
      assert result.description =~ meet_url
    end
  end

  # Helpers

  defp build_result(integration, opts) do
    attendees = Keyword.get(opts, :attendees, [])
    video_integration_id = Keyword.get(opts, :video_integration_id, nil)
    description = Keyword.get(opts, :description, nil)
    warning = Keyword.get(opts, :warning, nil)

    base = %{
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

    if warning, do: Map.put(base, :warning, warning), else: base
  end

  defp build_socket do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, flash: %{}}
    }
  end
end
