defmodule Tymeslot.Integrations.Video.TeamsDisconnectTest do
  @moduledoc """
  What disconnecting a Microsoft Teams video integration does to the rooms it
  made, and to the bookings that hold them afterwards.

  A Teams room comes in two shapes. When the booking's Outlook calendar is the
  same Microsoft account, the Teams meeting is switched on for the booking's
  own Outlook event, so the room id *is* that event's id
  (`video_room_id == provider_event_id`). Otherwise the Teams meeting is an
  event of its own in the Teams account's calendar.

  Disconnecting on its own keeps every room, for every provider: the join links
  are already in attendees' invites, and the meetings still exist in Microsoft.
  Disconnecting with `delete_rooms: true` deletes the upcoming rooms, which for
  an attached room must never mean deleting the booking's own event.
  """

  # Not async: a regression would call Graph through the application-wide
  # video circuit breaker.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :video
  @moduletag :integrations

  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.MeetingTestHelpers

  alias Tymeslot.Bookings.Create
  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EventVideoRooms
  alias Tymeslot.CalendarGrid.EventVideoRoomSchema
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.VideoIntegrationDisconnectWorker
  alias Tymeslot.Workers.VideoRoomWorker
  alias Tymeslot.Workers.VideoSyncWorker

  setup :verify_on_exit!

  @graph "https://graph.microsoft.com/v1.0"
  @booking_event "AAMk-booking-event"
  @teams_event "AAMk-teams-own-event"
  @organiser_url "https://teams.microsoft.com/l/meetup-join/organiser"
  @attendee_url "https://teams.microsoft.com/l/meetup-join/attendee"

  setup do
    %{user: user} = create_user_with_profile()
    teams = insert_teams_integration(user)

    stub(Tymeslot.TeamsOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

    # Graph answers every request and reports it, so each test can assert on
    # exactly which calls were (or were not) made.
    test_pid = self()

    stub(HTTPClientMock, :request, fn method, url, _body, _headers, _opts ->
      send(test_pid, {:graph_call, method, url})
      {:ok, %Req.Response{status: 204, body: ""}}
    end)

    %{user: user, teams: teams}
  end

  describe "disconnecting without deleting rooms" do
    test "keeps the Teams link on both attached and separate bookings", ctx do
      attached = insert_attached_booking(ctx.user, ctx.teams)
      separate = insert_separate_booking(ctx.user, ctx.teams)

      assert {:ok, :deleted} = Video.delete_integration(ctx.user.id, ctx.teams.id)

      refute_received {:graph_call, _method, _url}
      refute_enqueued(worker: VideoIntegrationDisconnectWorker)

      for {meeting, room_id} <- [{attached, @booking_event}, {separate, @teams_event}] do
        reloaded = Repo.reload!(meeting)
        # The foreign key is nilified; the provider and the room survive.
        assert reloaded.video_integration_id == nil
        assert reloaded.video_provider == "teams"
        assert reloaded.video_room_id == room_id
        assert reloaded.attendee_video_url == @attendee_url
        assert reloaded.organizer_video_url == @organiser_url
      end
    end

    test "a later reschedule of an attached booking leaves Graph alone and keeps the link",
         ctx do
      meeting = insert_attached_booking(ctx.user, ctx.teams)
      assert {:ok, :deleted} = Video.delete_integration(ctx.user.id, ctx.teams.id)

      # Calendar sync (through the still-connected Outlook calendar) moves the
      # event, and the Teams meeting on it with it.
      assert :ok =
               perform_job(VideoSyncWorker, %{"meeting_id" => meeting.id, "action" => "update"})

      refute_received {:graph_call, _method, _url}
      assert Repo.reload!(meeting).attendee_video_url == @attendee_url
    end

    test "a later reschedule of a separate booking is discarded, not retried, keeping the link",
         ctx do
      meeting = insert_separate_booking(ctx.user, ctx.teams)
      assert {:ok, :deleted} = Video.delete_integration(ctx.user.id, ctx.teams.id)

      # Nothing can authenticate against the Teams account any more, exactly as
      # for a disconnected Zoom integration: the job gives up loudly at once.
      assert {:discard, _reason} =
               perform_job(VideoSyncWorker, %{"meeting_id" => meeting.id, "action" => "update"})

      refute_received {:graph_call, _method, _url}

      reloaded = Repo.reload!(meeting)
      assert reloaded.video_room_id == @teams_event
      assert reloaded.attendee_video_url == @attendee_url
    end

    test "a later cancellation of an attached booking clears the room without calling Graph",
         ctx do
      meeting = insert_attached_booking(ctx.user, ctx.teams)
      assert {:ok, :deleted} = Video.delete_integration(ctx.user.id, ctx.teams.id)

      assert :ok =
               perform_job(VideoSyncWorker, %{"meeting_id" => meeting.id, "action" => "delete"})

      refute_received {:graph_call, _method, _url}

      reloaded = Repo.reload!(meeting)
      assert reloaded.video_room_id == nil
      # Still the booking's event, for calendar sync to cancel.
      assert reloaded.provider_event_id == @booking_event
    end

    test "a later cancellation of a separate booking keeps the room for a reconnect", ctx do
      meeting = insert_separate_booking(ctx.user, ctx.teams)
      assert {:ok, :deleted} = Video.delete_integration(ctx.user.id, ctx.teams.id)

      assert {:discard, _reason} =
               perform_job(VideoSyncWorker, %{"meeting_id" => meeting.id, "action" => "delete"})

      refute_received {:graph_call, _method, _url}

      # Still held, so `OrphanedVideoRoomScanWorker` can delete it once the
      # organiser reconnects Teams.
      assert Repo.reload!(meeting).video_room_id == @teams_event
    end

    test "the booking page stops offering the disconnected Teams integration", ctx do
      meeting_type =
        insert(:meeting_type,
          user: ctx.user,
          allow_video: true,
          video_integration: ctx.teams,
          locations: [video_location(ctx.teams, id: "loc-teams", label: "Teams")]
        )

      assert %{"loc-teams" => [%{provider: "teams"}]} =
               MeetingTypes.location_video_choices(meeting_type)

      assert {:ok, :deleted} = Video.delete_integration(ctx.user.id, ctx.teams.id)

      assert MeetingTypes.location_video_choices(Repo.reload!(meeting_type)) == %{}
    end
  end

  describe "disconnecting with delete_rooms: true" do
    test "deletes a separate Teams event and clears the booking's links", ctx do
      meeting = insert_separate_booking(ctx.user, ctx.teams)

      assert {:ok, :cleanup_scheduled} =
               Video.delete_integration(ctx.user.id, ctx.teams.id, delete_rooms: true)

      assert :ok =
               perform_job(VideoIntegrationDisconnectWorker, %{"integration_id" => ctx.teams.id})

      assert_received {:graph_call, :delete, url}
      assert url == "#{@graph}/me/events/#{@teams_event}"

      reloaded = Repo.reload!(meeting)
      assert reloaded.video_room_id == nil
      assert reloaded.attendee_video_url == nil

      assert_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "update", "meeting_id" => meeting.id}
      )

      assert {:error, :not_found} = VideoIntegrationQueries.get(ctx.teams.id)
    end

    # The attached room's id is the booking's own Outlook event. Deleting "the
    # room" through Graph deletes that event: the booking vanishes from the
    # organiser's calendar and Outlook mails attendees a cancellation. Graph
    # cannot take the online meeting off an event once set, so the way to drop
    # the link is the one `VideoSyncWorker.release/1` already takes: clear the
    # room locally and have calendar sync replace the event.
    test "never deletes the booking's own Outlook event for an attached room", ctx do
      meeting = insert_attached_booking(ctx.user, ctx.teams)

      assert {:ok, :cleanup_scheduled} =
               Video.delete_integration(ctx.user.id, ctx.teams.id, delete_rooms: true)

      assert :ok =
               perform_job(VideoIntegrationDisconnectWorker, %{"integration_id" => ctx.teams.id})

      refute_received {:graph_call, :delete, _url}

      reloaded = Repo.reload!(meeting)
      assert reloaded.video_room_id == nil
      assert reloaded.attendee_video_url == nil
      assert reloaded.provider_event_id == @booking_event

      assert_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "replace", "meeting_id" => meeting.id, "event_id" => @booking_event}
      )

      assert {:error, :not_found} = VideoIntegrationQueries.get(ctx.teams.id)
    end
  end

  describe "booking a meeting type whose Teams location outlived the integration" do
    setup do
      TestMocks.setup_calendar_mocks()
      TestMocks.setup_email_mocks()
      TestMocks.stub_no_calendar_events()

      %{user: user} = create_always_bookable_profile()
      teams = insert_teams_integration(user)

      meeting_type =
        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          allow_video: true,
          video_integration: teams,
          locations: [video_location(teams, id: "loc-teams", label: "Microsoft Teams")]
        )

      assert {:ok, :deleted} = Video.delete_integration(user.id, teams.id)

      %{user: user, meeting_type: meeting_type}
    end

    # The embedded location still names the deleted integration. The booking
    # must still go through, with no room promised on an integration that no
    # longer exists, rather than failing on the dangling reference.
    test "still books, without pointing the meeting at the deleted integration", ctx do
      params = %{
        date: Date.add(Date.utc_today(), 2),
        time: "14:00",
        duration: "30min",
        user_timezone: "Europe/London",
        organizer_user_id: ctx.user.id,
        meeting_type_id: ctx.meeting_type.id,
        location_option_id: "loc-teams"
      }

      form_data = %{"name" => "Ada", "email" => "ada@example.com", "message" => ""}

      assert {:ok, meeting} = Create.execute_with_video_room(params, form_data)
      assert meeting.video_integration_id == nil
      refute_enqueued(worker: VideoRoomWorker, args: %{"meeting_id" => meeting.id})
    end
  end

  describe "calendar grid events" do
    # A grid event's separate Teams event is recorded so that it follows its
    # grid event, not so that it is swept up with the integration: only
    # providers whose rooms linger until deleted are, so disconnecting with
    # its rooms has nothing of the grid's to delete, attached or not.
    test "a Teams room made for a grid event is left out of the disconnect", ctx do
      context = %{provider_type: :teams, room_data: %{room_id: @teams_event}}
      calendar = insert(:calendar_integration, user: ctx.user)
      start = DateTime.add(DateTime.utc_now(), 86_400, :second)

      assert :ok =
               EventVideoRooms.record(context, %{
                 user_id: ctx.user.id,
                 video_integration_id: ctx.teams.id,
                 calendar_integration_id: calendar.id,
                 uid: "grid-event",
                 all_day: false,
                 start: start,
                 end: DateTime.add(start, 3600, :second)
               })

      assert [%{room_id: @teams_event}] = Repo.all(EventVideoRoomSchema)

      now = DateTime.utc_now()
      assert CalendarGrid.count_event_video_rooms_for_integration(ctx.teams.id, :all, now) == 0
      assert Video.rooms_deleted_on_disconnect(ctx.user.id, ctx.teams.id).count == 0
    end
  end

  # Different days, so the two never collide on the organiser's one-booking-
  # per-slot constraint when a test holds both.
  defp insert_attached_booking(user, teams),
    do: insert_teams_booking(user, teams, @booking_event, @booking_event, 86_400)

  defp insert_separate_booking(user, teams),
    do: insert_teams_booking(user, teams, @teams_event, @booking_event, 2 * 86_400)

  defp insert_teams_booking(user, teams, room_id, provider_event_id, start_offset) do
    insert_meeting_for_user(user, %{
      start_offset: start_offset,
      video_integration_id: teams.id,
      video_provider: "teams",
      video_room_id: room_id,
      provider_event_id: provider_event_id,
      video_room_enabled: true,
      organizer_video_url: @organiser_url,
      attendee_video_url: @attendee_url
    })
  end

  defp insert_teams_integration(user) do
    insert(:video_integration,
      user: user,
      name: "Teams",
      provider: "teams",
      base_url: nil,
      api_key_encrypted: nil,
      access_token_encrypted: Encryption.encrypt("access-token"),
      refresh_token_encrypted: Encryption.encrypt("refresh-token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      oauth_scope: "https://graph.microsoft.com/Calendars.ReadWrite offline_access",
      provider_account_id: "entra-oid-1"
    )
  end
end
