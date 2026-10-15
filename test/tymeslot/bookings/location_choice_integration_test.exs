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
  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Emails.Templates.AppointmentConfirmation
  alias Tymeslot.Emails.Templates.AppointmentReminder
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Venues
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

      assert meeting.location == "Our office"
      assert meeting.location_kind == "in_person"
      assert meeting.location_option_id == "loc-office"
      assert meeting.video_integration_id == nil

      refute_enqueued(worker: VideoRoomWorker)
    end

    test "offering no venue records that the address is arranged after booking", ctx do
      assert {:ok, meeting} =
               book(ctx.meeting_type, ctx.user, %{location_option_id: "loc-office"})

      assert Repo.get!(MeetingSchema, meeting.id).address_to_arrange == true

      details = AppointmentBuilder.from_meeting(meeting)
      email = AppointmentConfirmation.render(:attendee, meeting.attendee_email, details)

      assert email.html_body =~ "The address will be arranged with you after booking."
      assert email.text_body =~ "The address will be arranged with you after booking."
      refute email.html_body =~ "arranged with the booker"
      refute email.text_body =~ "arranged with the booker"

      host_email = AppointmentConfirmation.render(:organizer, "organiser@example.com", details)

      assert host_email.html_body =~ "The address is to be arranged with the booker."
      assert host_email.text_body =~ "The address is to be arranged with the booker."
      refute host_email.html_body =~ "arranged with you"
      refute host_email.text_body =~ "arranged with you"
    end

    test "a location that is not in person has no address to arrange", ctx do
      assert {:ok, meeting} = book(ctx.meeting_type, ctx.user, %{location_option_id: "loc-video"})

      assert Repo.get!(MeetingSchema, meeting.id).address_to_arrange == false
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

    # The host has to call this number, so the confirmation that tells them
    # about the booking must carry it, not just a "Phone Call" label.
    test "shows the number in the host's confirmation email", ctx do
      assert {:ok, meeting} =
               book(ctx.meeting_type, ctx.user, %{
                 location_option_id: "loc-call",
                 location_phone: "+44 7700 900123"
               })

      details = AppointmentBuilder.from_meeting(meeting)
      email = AppointmentConfirmation.render(:organizer, meeting.organizer_email, details)

      assert email.html_body =~ "+44 7700 900123"
      assert email.text_body =~ "+44 7700 900123"
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

    test "a venue submitted against a location that is not in person is ignored", ctx do
      venue = insert(:venue, user: ctx.user)

      assert {:ok, meeting} =
               book(ctx.meeting_type, ctx.user, %{
                 location_option_id: "loc-video",
                 location_venue_id: venue.id
               })

      assert meeting.venue_id == nil
      assert meeting.location == "Zoom"
    end
  end

  describe "a location as long as the host is allowed to write" do
    test "reaches the meeting intact rather than failing at the column", ctx do
      name = String.duplicate("b", 120)
      description = String.duplicate("a", 500)
      venue = insert(:venue, user: ctx.user, name: name, description: description)

      long =
        insert(:meeting_type,
          user: ctx.user,
          name: "Long Address",
          locations: [in_person_location([venue], id: "loc-long", label: "Our office")]
        )

      assert {:ok, meeting} = book(long, ctx.user, %{location_option_id: "loc-long"})

      assert meeting.location == "#{name} (#{description})"
      assert String.length(meeting.location) > 255
    end
  end

  describe "an in-person location offering saved venues" do
    setup %{user: user} do
      berlin =
        insert(:venue,
          user: user,
          name: "Berlin office",
          description: "Friedrichstrasse 1\n3rd floor"
        )

      munich = insert(:venue, user: user, name: "Munich office", description: "Marienplatz 8")

      venue_type =
        insert(:meeting_type,
          user: user,
          name: "Office Visit",
          duration_minutes: 30,
          locations: [
            in_person_location([berlin, munich], id: "loc-offices", label: "Our offices")
          ]
        )

      %{berlin: berlin, munich: munich, venue_type: venue_type}
    end

    test "books the venue the booker picked and pins it on the meeting", ctx do
      assert {:ok, meeting} =
               book(ctx.venue_type, ctx.user, %{
                 location_option_id: "loc-offices",
                 location_venue_id: to_string(ctx.munich.id)
               })

      assert meeting.venue_id == ctx.munich.id
      assert meeting.location == "Munich office (Marienplatz 8)"
      assert meeting.location_kind == "in_person"
      assert Repo.get!(MeetingSchema, meeting.id).address_to_arrange == false
      refute_enqueued(worker: VideoRoomWorker)
    end

    test "deleting the booked venue does not make its address one to arrange", ctx do
      assert {:ok, meeting} =
               book(ctx.venue_type, ctx.user, %{
                 location_option_id: "loc-offices",
                 location_venue_id: ctx.munich.id
               })

      # Deleted while the location still lists it, so the location is
      # rewritten too; the meeting keeps what it was booked at.
      assert {:ok, _deleted} = Venues.delete_venue(ctx.munich)
      reloaded = Repo.get!(MeetingSchema, meeting.id)

      assert reloaded.venue_id == nil
      assert reloaded.address_to_arrange == false

      details = AppointmentBuilder.from_meeting(reloaded)
      email = AppointmentConfirmation.render(:attendee, reloaded.attendee_email, details)

      assert reloaded.location == "Munich office (Marienplatz 8)"
      assert email.text_body =~ "Munich office (Marienplatz 8)"
      refute email.text_body =~ "arranged with you after booking"

      # The reminders still to come name it too, for the booker and the host.
      for {role, recipient} <- [
            attendee: details.attendee_email,
            organizer: details.organizer_email
          ] do
        reminder = AppointmentReminder.render(role, recipient, details)

        assert reminder.html_body =~ "Munich office"
        assert reminder.text_body =~ "Munich office (Marienplatz 8)"
        refute reminder.text_body =~ "to be arranged"
        refute reminder.text_body =~ "arranged with you after booking"
      end
    end

    test "deleting a location's only venue makes its next booking one to arrange", ctx do
      solo =
        insert(:meeting_type,
          user: ctx.user,
          name: "Berlin Visit",
          duration_minutes: 30,
          locations: [in_person_location([ctx.berlin], id: "loc-berlin", label: "Berlin")]
        )

      assert {:ok, _deleted} = Venues.delete_venue(ctx.berlin)

      assert {:ok, meeting} =
               book(solo, ctx.user, %{
                 location_option_id: "loc-berlin",
                 location_venue_id: ctx.berlin.id
               })

      reloaded = Repo.get!(MeetingSchema, meeting.id)
      assert reloaded.venue_id == nil
      assert reloaded.location == "Berlin"
      assert reloaded.address_to_arrange == true
    end

    test "a venue the location does not offer books its first venue instead", ctx do
      stranger = insert(:venue)

      assert {:ok, meeting} =
               book(ctx.venue_type, ctx.user, %{
                 location_option_id: "loc-offices",
                 location_venue_id: stranger.id
               })

      assert meeting.venue_id == ctx.berlin.id
      assert meeting.location == "Berlin office (Friedrichstrasse 1, 3rd floor)"
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
