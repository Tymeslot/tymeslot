defmodule TymeslotWeb.SavedLocationsJourneyTest do
  @moduledoc """
  Saved locations end to end, across the surfaces a real organiser and
  booker cross:

    1. The organiser adds a location on the Locations page and offers it,
       with one already saved, on a meeting type; a booker picks the second;
       the meeting, the confirmation email and the calendar event all carry
       it. On every theme.
    2. On a meeting type offering in person and video, a booker who chooses
       video gets a video room and no venue.
    3. An in-person location without a venue tells the booker the address
       will be arranged: on the booking step, on the confirmation and in the
       email, while the host's email words it for the host. On every theme.
    4. A reschedule moves the meeting to another venue.
    5. Deleting a location a meeting type offers, and a meeting is booked at:
       the Locations page warns first, the booked meeting keeps its address,
       and the next booker is told the address will be arranged.

  "+ New location" in the meeting-type editor (journey 6) is covered by
  `LocationsEditorTest`.
  """
  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integration
  @moduletag :scheduling
  @moduletag :meeting_types
  @moduletag :live

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.BookingTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Emails.Templates.AppointmentConfirmation
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.CalendarEventBuilder
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias Tymeslot.Venues
  alias Tymeslot.Workers.VideoRoomWorker

  @themes [{"Quill", "1"}, {"Rhythm", "2"}]
  @note "The address will be arranged with you after booking."
  @host_note "The address is to be arranged with the booker."

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    old_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(old_cfg, :booking_enabled, false))
    on_exit(fn -> Application.put_env(:tymeslot, :recaptcha, old_cfg) end)

    TestMocks.setup_all_mocks()

    %{user: insert(:user, onboarding_completed_at: DateTime.utc_now())}
  end

  defp bookable_profile(user, theme_id) do
    profile =
      insert(:profile,
        user: user,
        username: "journey#{theme_id}",
        booking_theme: theme_id,
        timezone: "America/New_York"
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_minutes: 0
      )

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    insert(:calendar_integration, user: user, is_active: true)
    profile
  end

  defp organiser_conn(user) do
    build_conn()
    |> init_test_session(%{})
    |> fetch_session()
    |> log_in_user(user)
  end

  # Saving, deleting and the meeting-type auto-save all land through
  # messages to the LiveView; draining its mailbox makes them observable.
  defp drain(view), do: :sys.get_state(view.pid)

  defp add_location(conn, attrs) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/locations")
    view |> element("[data-testid='add-venue']") |> render_click()
    view |> form("#venue-form", %{"venue" => attrs}) |> render_submit()
    drain(view)
  end

  defp offer_venues(conn, meeting_type, venues) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view
    |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    view |> element("[phx-click='switch_tab'][phx-value-tab='location']") |> render_click()

    view
    |> element("[phx-click='edit_location'][phx-value-id='loc-offices']")
    |> render_click()

    view
    |> form("#location-editor-form", %{
      "location" => %{
        "kind" => "in_person",
        "label" => "Our offices",
        "venue_ids" => ["" | Enum.map(venues, &to_string(&1.id))]
      }
    })
    |> render_submit()

    drain(view)
  end

  defp pick_venue(view, venue) do
    view
    |> element("[data-testid='venue-option'][data-venue-id='#{venue.id}'] input")
    |> render_click()

    drain(view)
  end

  defp submit(view, email) do
    view
    |> form("form[phx-submit='submit']", %{
      "booking" => %{"name" => "Booker", "email" => email, "message" => ""}
    })
    |> render_submit()

    drain(view)
    render(view)
  end

  defp booked(email) do
    assert [meeting] = Repo.all_by(MeetingSchema, attendee_email: email)
    meeting
  end

  defp confirmation_email(meeting, :attendee) do
    AppointmentConfirmation.render(
      :attendee,
      meeting.attendee_email,
      AppointmentBuilder.from_meeting(meeting)
    )
  end

  defp confirmation_email(meeting, :organizer) do
    AppointmentConfirmation.render(
      :organizer,
      meeting.organizer_email,
      AppointmentBuilder.from_meeting(meeting)
    )
  end

  for {theme_name, theme_id} <- @themes do
    describe "#{theme_name}: journey 1, from the Locations page to the booker's calendar" do
      setup %{user: user} do
        berlin =
          insert(:venue, user: user, name: "Berlin office", description: "Friedrichstrasse 1")

        meeting_type =
          insert(:meeting_type,
            user: user,
            duration_minutes: 30,
            name: "Consultation",
            is_active: true,
            locations: [in_person_location([berlin], id: "loc-offices", label: "Our offices")]
          )

        %{
          profile: bookable_profile(user, unquote(theme_id)),
          berlin: berlin,
          meeting_type: meeting_type
        }
      end

      @tag :capture_log
      test "a location added on the dashboard reaches the meeting, the email and the calendar",
           ctx do
        organiser = organiser_conn(ctx.user)

        add_location(organiser, %{"name" => "Munich office", "description" => "Marienplatz 8"})
        assert [_berlin, munich] = Venues.list_venues(ctx.user.id)
        assert munich.name == "Munich office"

        offer_venues(organiser, ctx.meeting_type, [ctx.berlin, munich])

        view = navigate_to_booking_form(ctx.conn, ctx.profile, nil)
        pick_venue(view, munich)
        submit(view, "journey@example.com")

        meeting = booked("journey@example.com")
        assert meeting.venue_id == munich.id
        assert meeting.location == "Munich office (Marienplatz 8)"
        assert meeting.address_to_arrange == false

        assert has_element?(
                 view,
                 "[data-testid='confirmation-location']",
                 "Munich office (Marienplatz 8)"
               )

        email = confirmation_email(meeting, :attendee)
        assert email.html_body =~ "Munich office (Marienplatz 8)"
        assert email.text_body =~ "Munich office (Marienplatz 8)"
        refute email.text_body =~ @note

        assert CalendarEventBuilder.build_event_data(meeting).location ==
                 "Munich office (Marienplatz 8)"
      end
    end

    describe "#{theme_name}: journey 3, an in-person location without an address" do
      setup %{user: user} do
        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          name: "Consultation",
          is_active: true,
          locations: [in_person_location([], id: "loc-in-person", label: "In person")]
        )

        %{profile: bookable_profile(user, unquote(theme_id))}
      end

      @tag :capture_log
      test "the booker is told the address will be arranged, before and after booking and by email",
           ctx do
        view = navigate_to_booking_form(ctx.conn, ctx.profile, nil)

        assert has_element?(view, "[data-testid='location-stated']", @note)

        submit(view, "arranged@example.com")

        assert has_element?(view, "[data-testid='location-arranged-note']", @note)

        meeting = booked("arranged@example.com")
        assert meeting.venue_id == nil
        assert meeting.address_to_arrange == true

        email = confirmation_email(meeting, :attendee)
        assert email.html_body =~ @note
        assert email.text_body =~ @note

        host_email = confirmation_email(meeting, :organizer)
        assert host_email.html_body =~ @host_note
        refute host_email.html_body =~ @note

        assert CalendarEventBuilder.build_event_data(meeting).location == "In person"
      end
    end
  end

  describe "journey 2: a meeting type offering in person and video" do
    setup %{user: user} do
      berlin =
        insert(:venue, user: user, name: "Berlin office", description: "Friedrichstrasse 1")

      integration =
        insert(:video_integration,
          user: user,
          name: "Zoom",
          provider: "mirotalk",
          is_active: true
        )

      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        name: "Consultation",
        is_active: true,
        allow_video: true,
        video_integration: integration,
        locations: [
          in_person_location([berlin], id: "loc-office", label: "Our office"),
          video_location(integration, id: "loc-video", label: "Video call", position: 1)
        ]
      )

      %{profile: bookable_profile(user, "1"), integration: integration}
    end

    @tag :capture_log
    test "a booker who chooses video gets a video room and no venue", ctx do
      view = navigate_to_booking_form(ctx.conn, ctx.profile, nil)

      # In person is the first location, so its venue shows until the booker
      # moves to video.
      assert has_element?(view, "[data-testid='location-detail']", "Berlin office")

      view |> element("[data-location-id='loc-video'] input") |> render_click()
      drain(view)

      refute has_element?(view, "[data-testid='location-detail']", "Berlin office")

      submit(view, "video@example.com")

      meeting = booked("video@example.com")
      assert meeting.location_kind == "video"
      assert meeting.video_integration_id == ctx.integration.id
      assert meeting.venue_id == nil
      assert meeting.address_to_arrange == false
      assert_enqueued(worker: VideoRoomWorker, args: %{"meeting_id" => meeting.id})
    end
  end

  describe "journey 4: a reschedule moves the meeting to another venue" do
    setup %{user: user} do
      berlin =
        insert(:venue, user: user, name: "Berlin office", description: "Friedrichstrasse 1")

      munich = insert(:venue, user: user, name: "Munich office", description: "Marienplatz 8")

      meeting_type =
        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          name: "Consultation",
          is_active: true,
          locations: [
            in_person_location([berlin, munich], id: "loc-offices", label: "Our offices")
          ]
        )

      start = DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          meeting_type_id: meeting_type.id,
          attendee_name: "Booker",
          attendee_email: "rebook@example.com",
          attendee_timezone: "America/New_York",
          start_time: start,
          end_time: DateTime.add(start, 30, :minute),
          duration: 30,
          status: "confirmed",
          location: "Berlin office (Friedrichstrasse 1)",
          location_kind: "in_person",
          location_option_id: "loc-offices",
          venue_id: berlin.id
        )

      %{
        profile: bookable_profile(user, "1"),
        berlin: berlin,
        munich: munich,
        meeting: meeting,
        original_start: start
      }
    end

    @tag :capture_log
    test "the picker opens on the meeting's venue, and choosing another moves the meeting",
         ctx do
      view =
        navigate_to_booking_form(ctx.conn, ctx.profile, nil,
          reschedule_meeting_uid: ctx.meeting.uid
        )

      assert has_element?(view, "[data-venue-id='#{ctx.berlin.id}'] input[checked]")

      pick_venue(view, ctx.munich)
      submit(view, ctx.meeting.attendee_email)

      wait_until(fn ->
        Repo.get!(MeetingSchema, ctx.meeting.id).start_time != ctx.original_start
      end)

      moved = Repo.get!(MeetingSchema, ctx.meeting.id)
      assert moved.venue_id == ctx.munich.id
      assert moved.location == "Munich office (Marienplatz 8)"
      assert moved.address_to_arrange == false

      # Moved, not rebooked.
      assert [_only] = Repo.all_by(MeetingSchema, attendee_email: "rebook@example.com")
    end
  end

  describe "journey 5: deleting a location a meeting is booked at" do
    setup %{user: user} do
      berlin =
        insert(:venue, user: user, name: "Berlin office", description: "Friedrichstrasse 1")

      meeting_type =
        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          name: "Consultation",
          is_active: true,
          locations: [in_person_location([berlin], id: "loc-office", label: "Our office")]
        )

      %{profile: bookable_profile(user, "1"), berlin: berlin, meeting_type: meeting_type}
    end

    @tag :capture_log
    test "the booked meeting keeps its address, and the next booker is told it will be arranged",
         ctx do
      view = navigate_to_booking_form(ctx.conn, ctx.profile, nil)
      assert has_element?(view, "[data-testid='location-stated']", "Berlin office")
      submit(view, "before@example.com")

      before = booked("before@example.com")
      assert before.venue_id == ctx.berlin.id

      {:ok, page, _html} = live(organiser_conn(ctx.user), ~p"/dashboard/locations")

      page
      |> element("[phx-click='delete_venue'][phx-value-id='#{ctx.berlin.id}']")
      |> render_click()

      assert has_element?(page, "[data-testid='venue-in-use']", "Consultation")
      assert has_element?(page, "[data-testid='venue-left-without']", "Consultation")

      page |> element("[data-testid='confirm-delete-venue']") |> render_click()
      drain(page)

      refute has_element?(page, "[data-testid='venue-card']")
      assert Venues.list_venues(ctx.user.id) == []

      assert [%{venue_ids: []}] =
               MeetingTypes.get_meeting_type(ctx.meeting_type.id, ctx.user.id).locations

      kept = Repo.get!(MeetingSchema, before.id)
      assert kept.location == "Berlin office (Friedrichstrasse 1)"
      assert kept.venue_id == nil
      assert kept.address_to_arrange == false

      RateLimiter.clear_all()
      AvailabilityCache.clear_all()

      next = navigate_to_booking_form(ctx.conn, ctx.profile, nil)
      assert has_element?(next, "[data-testid='location-stated']", @note)
      refute has_element?(next, "[data-testid='location-stated']", "Berlin office")
      submit(next, "after@example.com")

      after_delete = booked("after@example.com")
      assert after_delete.venue_id == nil
      assert after_delete.address_to_arrange == true
      assert after_delete.location == "Our office"
    end
  end
end
