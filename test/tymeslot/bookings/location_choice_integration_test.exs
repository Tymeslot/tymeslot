defmodule Tymeslot.Bookings.LocationChoiceIntegrationTest do
  @moduledoc """
  End-to-end coverage of the booker choosing where a meeting is held.

  The booker submits an option id and nothing else. Everything that follows
  from it — the location string the calendar event and confirmation emails
  show, the recorded kind, and whether a video room is created and on which
  integration — is derived server-side from the host's own meeting type, so
  these tests drive the real booking path rather than `LocationSelection` in
  isolation.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :integration

  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Bookings.Create
  alias Tymeslot.Integrations.Video
  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.VideoRoomWorker

  setup do
    TestMocks.setup_calendar_mocks()
    TestMocks.setup_email_mocks()

    Mox.stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user, _from, _to ->
      {:ok, []}
    end)

    user = insert(:user, email: "organiser@example.com", name: "Organiser")
    profile = insert(:profile, user: user, timezone: "Europe/London")
    # Location is the subject here, so the host offers every hour of every day
    # and the schedule never refuses the bookings these tests make.
    _schedule = open_schedule_for(profile)

    integration = insert(:video_integration, user: user, provider: "mirotalk")

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Consultation",
        duration_minutes: 30,
        # The changeset projects these two from the list; the factory writes
        # the row directly, so they are set by hand to the values a real save
        # would have produced. Without them the "in-person creates no room"
        # test would pass for the wrong reason: there would be no meeting
        # type-level integration for the location to have to override.
        allow_video: true,
        video_integration: integration,
        locations: [
          %LocationOption{
            id: "loc-office",
            kind: "in_person",
            label: "Our office",
            details: "12 High Street",
            position: 0
          },
          video_location(integration, id: "loc-video", label: "Zoom", position: 1),
          %LocationOption{
            id: "loc-call",
            kind: "phone",
            label: "Phone call",
            collect_from_guest: true,
            position: 2
          }
        ]
      )

    %{user: user, integration: integration, meeting_type: meeting_type}
  end

  defp book(meeting_type, user, extra) do
    params =
      Map.merge(
        %{
          date: Date.add(Date.utc_today(), 1),
          time: "14:00",
          duration: "30min",
          user_timezone: "Europe/London",
          organizer_user_id: user.id,
          meeting_type_id: meeting_type.id
        },
        extra
      )

    form_data = %{
      "name" => "Booker",
      "email" => "booker@example.com",
      "message" => ""
    }

    Create.execute_with_video_room(params, form_data)
  end

  describe "an in-person location" do
    test "writes the host's own words to the meeting and creates no room", ctx do
      assert {:ok, meeting} =
               book(ctx.meeting_type, ctx.user, %{location_option_id: "loc-office"})

      assert meeting.location == "Our office (12 High Street)"
      assert meeting.location_kind == "in_person"
      assert meeting.location_option_id == "loc-office"
      assert meeting.video_integration_id == nil

      refute_enqueued(worker: VideoRoomWorker)
    end
  end

  describe "a video location" do
    test "routes the room to the integration that location names", ctx do
      assert {:ok, meeting} =
               book(ctx.meeting_type, ctx.user, %{location_option_id: "loc-video"})

      assert meeting.location == "Zoom"
      assert meeting.location_kind == "video"
      assert meeting.video_integration_id == ctx.integration.id

      assert_enqueued(worker: VideoRoomWorker, args: %{"meeting_id" => meeting.id})
    end
  end

  describe "a video location offering several providers" do
    setup %{user: user, integration: first} do
      second = insert(:video_integration, user: user, provider: "mirotalk", name: "Second")

      meeting_type =
        insert(:meeting_type,
          user: user,
          name: "Pick a provider",
          duration_minutes: 30,
          allow_video: true,
          video_integration: first,
          locations: [video_location([first, second], id: "loc-video", position: 0)]
        )

      %{meeting_type: meeting_type, second: second}
    end

    test "creates the room on the provider the booker picked", ctx do
      assert {:ok, meeting} =
               book(ctx.meeting_type, ctx.user, %{
                 location_option_id: "loc-video",
                 location_video_integration_id: to_string(ctx.second.id)
               })

      assert meeting.video_integration_id == ctx.second.id
      assert_enqueued(worker: VideoRoomWorker, args: %{"meeting_id" => meeting.id})
    end

    test "falls back to the first provider for one the location does not list", ctx do
      stranger = insert(:video_integration, provider: "mirotalk")

      assert {:ok, meeting} =
               book(ctx.meeting_type, ctx.user, %{
                 location_option_id: "loc-video",
                 location_video_integration_id: stranger.id
               })

      assert meeting.video_integration_id == ctx.integration.id
    end

    # The location still lists the first provider after the host disconnected
    # it, and would otherwise resolve to it as the booker's default.
    test "passes over a provider the host has since disconnected", ctx do
      assert {:ok, :deleted} = Video.delete_integration(ctx.user.id, ctx.integration.id)

      assert {:ok, meeting} = book(ctx.meeting_type, ctx.user, %{location_option_id: "loc-video"})

      assert meeting.video_integration_id == ctx.second.id
      assert_enqueued(worker: VideoRoomWorker, args: %{"meeting_id" => meeting.id})
    end
  end

  describe "a phone location that asks the booker for their number" do
    test "records the number on the meeting and in its location", ctx do
      assert {:ok, meeting} =
               book(ctx.meeting_type, ctx.user, %{
                 location_option_id: "loc-call",
                 location_phone: "+44 7700 900123"
               })

      assert meeting.location == "Phone call (+44 7700 900123)"
      assert meeting.location_kind == "phone"
      assert meeting.attendee_phone == "+44 7700 900123"
      assert meeting.video_integration_id == nil
    end
  end

  describe "a submitted id that is not one of the host's" do
    test "falls back to the first location instead of being honoured", ctx do
      assert {:ok, meeting} =
               book(ctx.meeting_type, ctx.user, %{location_option_id: "loc-forged"})

      assert meeting.location_option_id == "loc-office"
      assert meeting.video_integration_id == nil
    end

    test "a number submitted against a non-phone location is not recorded", ctx do
      assert {:ok, meeting} =
               book(ctx.meeting_type, ctx.user, %{
                 location_option_id: "loc-video",
                 location_phone: "+44 7700 900123"
               })

      assert meeting.attendee_phone == nil
      assert meeting.location == "Zoom"
    end
  end

  describe "a location as long as the host is allowed to write" do
    test "reaches the meeting intact rather than failing at the column", ctx do
      details = String.duplicate("a", 500)
      label = String.duplicate("b", 120)

      long =
        insert(:meeting_type,
          user: ctx.user,
          name: "Long Address",
          locations: [
            %LocationOption{
              id: "loc-long",
              kind: "in_person",
              label: label,
              details: details,
              position: 0
            }
          ]
        )

      assert {:ok, meeting} = book(long, ctx.user, %{location_option_id: "loc-long"})

      assert meeting.location == "#{label} (#{details})"
      assert String.length(meeting.location) > 255
    end
  end

  describe "a meeting type saved before locations existed" do
    test "still books against the single location its old fields describe", ctx do
      legacy =
        insert(:meeting_type,
          user: ctx.user,
          name: "Legacy Video",
          allow_video: true,
          video_integration: ctx.integration,
          locations: []
        )

      assert {:ok, meeting} = book(legacy, ctx.user, %{})

      assert meeting.location_kind == "video"
      assert meeting.video_integration_id == ctx.integration.id
      assert_enqueued(worker: VideoRoomWorker, args: %{"meeting_id" => meeting.id})
    end
  end
end
