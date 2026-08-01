defmodule Tymeslot.CalendarGrid.EventCreationTest do
  @moduledoc """
  Unit/integration tests for the domain orchestration that creates calendar-grid
  events.

  These cover `run_create_event/1` — which routes success notifications through
  `AttendeeNotifications.event_created/2`, and (when a video integration is
  selected) provisions a meeting room and surfaces its URL in the invitation
  email's description payload — plus `run_create_ad_hoc_meeting/1` and the
  `:reauth_required` signal the orchestration returns (rather than flashing)
  when an integration's credentials need re-encrypting.

  The full provider-call path is stubbed: we fake `EventOperations.create_event`
  via `Tymeslot.CalendarMock` and the MiroTalk provider via `HTTPClientMock`.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid.EventCreation
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

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
        # 8 random bytes, Base16-encoded — Google's idempotency key.
        assert cr[:requestId] =~ ~r/^[0-9A-F]{16}$/

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
        assert {:ok, result} = EventCreation.run_create_event(payload)

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
        assert {:ok, result} = EventCreation.run_create_event(payload)

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

      # Route the provider call through the Mox-backed mock so
      # we don't need a real CalDAV server for the test.
      original =
        Application.get_env(:tymeslot, :event_create_operations_module)

      Application.put_env(
        :tymeslot,
        :event_create_operations_module,
        Tymeslot.CalendarMock
      )

      try do
        assert {:ok, result} = EventCreation.run_create_event(payload)

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

  describe "run_create_event/1 — credentials require re-encryption" do
    test "flags the integration for reauth and returns reauth_required: true (no send/2)" do
      user = insert(:user)

      # Undecryptable credential bytes make CalendarIntegrationQueries.get/1 return
      # {:error, :requires_reencryption, integration} — the path that previously
      # tried (and failed, from inside a Task) to flash the user.
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          username_encrypted: :crypto.strong_rand_bytes(40),
          password_encrypted: :crypto.strong_rand_bytes(40)
        )

      expect(Tymeslot.CalendarMock, :create_event, fn _event_data, _context ->
        {:ok, "reauth-uid-1"}
      end)

      payload = %{
        creating: %{
          title: "Needs Reconnect",
          integration_id: integration.id,
          calendar_id: "primary",
          attendees: [],
          video_integration_id: nil
        },
        user_id: user.id,
        start_at: ~U[2026-04-08 09:00:00Z],
        end_at: ~U[2026-04-08 09:30:00Z]
      }

      original = Application.get_env(:tymeslot, :event_create_operations_module)
      Application.put_env(:tymeslot, :event_create_operations_module, Tymeslot.CalendarMock)

      try do
        assert {:ok, result} = EventCreation.run_create_event(payload)

        assert result.reauth_required == true
        assert result.provider == nil
        assert result.default_booking_calendar_id == nil

        # The real DB side effect still happens: the integration is flagged.
        reloaded = Repo.get!(CalendarIntegrationSchema, integration.id)
        assert reloaded.needs_reauth == true

        # The signal is data, not a flash sent back to the caller process.
        refute_received {:flash, _}
      after
        if original do
          Application.put_env(:tymeslot, :event_create_operations_module, original)
        else
          Application.delete_env(:tymeslot, :event_create_operations_module)
        end
      end
    end

    test "returns reauth_required: false on the happy path" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      expect(Tymeslot.CalendarMock, :create_event, fn _event_data, _context ->
        {:ok, "ok-uid-1"}
      end)

      payload = %{
        creating: %{
          title: "All Good",
          integration_id: integration.id,
          calendar_id: "primary",
          attendees: [],
          video_integration_id: nil
        },
        user_id: user.id,
        start_at: ~U[2026-04-08 11:00:00Z],
        end_at: ~U[2026-04-08 11:30:00Z]
      }

      original = Application.get_env(:tymeslot, :event_create_operations_module)
      Application.put_env(:tymeslot, :event_create_operations_module, Tymeslot.CalendarMock)

      try do
        assert {:ok, result} = EventCreation.run_create_event(payload)
        assert result.reauth_required == false
      after
        if original do
          Application.put_env(:tymeslot, :event_create_operations_module, original)
        else
          Application.delete_env(:tymeslot, :event_create_operations_module)
        end
      end
    end
  end

  describe "run_create_ad_hoc_meeting/1" do
    test "creates a meeting and returns its id with the start/end times" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      start_at = ~U[2026-04-09 13:00:00Z]
      end_at = ~U[2026-04-09 13:30:00Z]

      stub(Tymeslot.CalendarMock, :create_event, fn _event_data, _context ->
        {:ok, "ad-hoc-uid-1"}
      end)

      params = %{
        title: "Ad-hoc Chat",
        start_time: start_at,
        end_time: end_at,
        attendee_name: "Alice",
        attendee_email: "alice@example.com",
        attendee_timezone: "Etc/UTC",
        organizer_user_id: user.id,
        calendar_integration_id: integration.id,
        calendar_id: "primary",
        video_integration_id: nil
      }

      original = Application.get_env(:tymeslot, :event_create_operations_module)
      Application.put_env(:tymeslot, :event_create_operations_module, Tymeslot.CalendarMock)

      try do
        assert {:ok, result} = EventCreation.run_create_ad_hoc_meeting(params)

        assert %MeetingSchema{title: "Ad-hoc Chat", attendee_email: "alice@example.com"} =
                 Repo.get!(MeetingSchema, result.meeting_id)

        assert result.start_at == start_at
        assert result.end_at == end_at
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
      # This is the only test that drives the *real* calendar client path
      # (the others stub `EventOperations` via `Tymeslot.CalendarMock`).
      # `ClientManager.booking_client/1` gates on
      # `function_exported?(Google.Provider, :build_booking_client_config, 1)`,
      # and `function_exported?/3` reports `false` for a module the VM has not
      # yet code-loaded. Under lazy loading that happens whenever this test does
      # not run first, yielding a spurious `{:error, :no_calendar_client}`.
      # Force the provider module to load so the gate reflects reality.
      Code.ensure_loaded!(Tymeslot.Integrations.Calendar.Google.Provider)
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

        assert %{"conferenceSolutionKey" => %{"type" => "hangoutsMeet"}} =
                 get_in(decoded, ["conferenceData", "createRequest"])

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

      assert {:ok, result} = EventCreation.run_create_event(payload)
      assert result.meeting_url == meet_url
      assert result.video_room_id == "abc-defg-hij"
      assert result.creating.video_integration_id == video_integration.id
      assert result.description =~ meet_url
    end
  end
end
