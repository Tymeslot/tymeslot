defmodule TymeslotWeb.Live.Scheduling.LocationChoiceFlowTest do
  @moduledoc """
  End-to-end integration test for the booker choosing a location on the Quill
  theme.

  Exercises the full journey when a meeting type offers more than one place
  to meet:

    * The picker renders, one option per location, with the host's first
      preselected so the form is never submittable in an unanswered state.
    * Choosing an option moves the selection.
    * A phone option that asks for the booker's number reveals a number
      input, and submitting without one is refused with an inline error
      rather than creating a half-addressed meeting.
    * Submitting persists the chosen location on the meeting, verified by
      reading the row back.
    * A meeting type with a single location renders no picker at all, and
      still records that location on the booking.
    * A reschedule offers the same picker, opened on where the meeting
      already is, and moving it persists on the existing meeting. With a
      single location there is nothing to choose, and the meeting keeps its
      location even if the host has replaced that location since.

  Events are driven through the parent LiveView's `{:step_event, :booking, …}`
  message path, the same path `BookingComponent` uses to relay picker events
  from the LiveComponent to the root LiveView. `guest_booking_flow_test.exs`
  covers the equivalent journey for the guest field.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :scheduling
  @moduletag :live

  import Mox
  import Tymeslot.BookingTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias TymeslotWeb.Themes.Shared.BookingLocation

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    old_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(old_cfg, :booking_enabled, false))
    on_exit(fn -> Application.put_env(:tymeslot, :recaptcha, old_cfg) end)

    TestMocks.setup_all_mocks()

    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "locationbooker",
        booking_theme: "1",
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

    %{profile: profile, user: user}
  end

  defp office do
    %LocationOption{
      id: "loc-office",
      kind: "in_person",
      label: "Our office",
      position: 0
    }
  end

  defp call_me do
    %LocationOption{
      id: "loc-call",
      kind: "phone",
      label: "Phone call",
      collect_from_guest: true,
      position: 1
    }
  end

  defp submit(view, email) do
    view
    |> form("form[phx-submit='submit']", %{
      "booking" => %{"name" => "Booker", "email" => email, "message" => ""}
    })
    |> render_submit()

    _drain = :sys.get_state(view.pid)
    render(view)
  end

  describe "a meeting type offering several locations" do
    setup %{user: user} do
      meeting_type =
        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          name: "Consultation",
          is_active: true,
          locations: [office(), call_me()]
        )

      %{meeting_type: meeting_type}
    end

    @tag :capture_log
    test "renders one option per location, with the host's first preselected",
         %{conn: conn, profile: profile} do
      view = navigate_to_booking_form(conn, profile, nil)

      assert has_element?(view, "[data-testid='location-field']")
      assert has_element?(view, "[data-location-id='loc-office']")
      assert has_element?(view, "[data-location-id='loc-call']")

      assert has_element?(view, "[data-testid='location-arranged-note']")
      assert :sys.get_state(view.pid).socket.assigns.selected_location_id == "loc-office"
    end

    @tag :capture_log
    test "choosing an option moves the selection", %{conn: conn, profile: profile} do
      view = navigate_to_booking_form(conn, profile, nil)

      send(view.pid, {:step_event, :booking, :select_location, "loc-call"})
      _drain = :sys.get_state(view.pid)

      assert :sys.get_state(view.pid).socket.assigns.selected_location_id == "loc-call"
      assert has_element?(view, "[data-testid='location-phone']")
    end

    @tag :capture_log
    test "shows the detail of the chosen option only", %{conn: conn, profile: profile} do
      view = navigate_to_booking_form(conn, profile, nil)

      assert has_element?(view, "[data-testid='location-arranged-note']")

      send(view.pid, {:step_event, :booking, :select_location, "loc-call"})
      _drain = :sys.get_state(view.pid)

      detail = view |> element("[data-testid='location-detail']") |> render()
      assert detail =~ "We&#39;ll call you"
      refute has_element?(view, "[data-testid='location-arranged-note']")
    end

    @tag :capture_log
    test "an id that is not on offer is ignored rather than stored",
         %{conn: conn, profile: profile} do
      view = navigate_to_booking_form(conn, profile, nil)

      send(view.pid, {:step_event, :booking, :select_location, "loc-forged"})
      _drain = :sys.get_state(view.pid)

      assert :sys.get_state(view.pid).socket.assigns.selected_location_id == "loc-office"
    end

    @tag :capture_log
    test "submitting without the number a phone location asked for is refused",
         %{conn: conn, profile: profile} do
      view = navigate_to_booking_form(conn, profile, nil)

      send(view.pid, {:step_event, :booking, :select_location, "loc-call"})
      _drain = :sys.get_state(view.pid)

      html = submit(view, "nophone@example.com")

      assert has_element?(view, "[data-testid='location-error']")
      assert html =~ "Enter the number we should call you on."
      refute html =~ "Meeting Confirmed"
      assert Repo.all_by(MeetingSchema, attendee_email: "nophone@example.com") == []
    end

    @tag :capture_log
    test "the chosen location and the booker's number reach the meeting",
         %{conn: conn, profile: profile} do
      view = navigate_to_booking_form(conn, profile, nil)

      send(view.pid, {:step_event, :booking, :select_location, "loc-call"})
      send(view.pid, {:step_event, :booking, :location_phone, "+1 555 0100"})
      _drain = :sys.get_state(view.pid)

      html = submit(view, "phone@example.com")

      assert html =~ "Meeting Confirmed"
      assert html =~ "Phone call (+1 555 0100)"

      assert [meeting] = Repo.all_by(MeetingSchema, attendee_email: "phone@example.com")
      assert meeting.location == "Phone call (+1 555 0100)"
      assert meeting.location_kind == "phone"
      assert meeting.location_option_id == "loc-call"
      assert meeting.attendee_phone == "+1 555 0100"
    end

    @tag :capture_log
    test "the host's first location is what an untouched picker books",
         %{conn: conn, profile: profile} do
      view = navigate_to_booking_form(conn, profile, nil)

      assert submit(view, "default@example.com") =~ "Meeting Confirmed"

      assert [meeting] = Repo.all_by(MeetingSchema, attendee_email: "default@example.com")
      assert meeting.location == "Our office"
      assert meeting.location_option_id == "loc-office"
    end
  end

  describe "a video location offering several providers" do
    setup %{user: user} do
      first = insert(:video_integration, user: user, name: "Zoom", is_active: true)
      second = insert(:video_integration, user: user, name: "Teams", is_active: true)
      retired = insert(:video_integration, user: user, name: "Retired", is_active: false)

      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        name: "Video Chat",
        is_active: true,
        locations: [
          video_location([first, retired, second], id: "loc-video", label: "Video call")
        ]
      )

      %{first: first, second: second}
    end

    @tag :capture_log
    test "asks which provider, offering only the active ones, with the first preselected",
         %{conn: conn, profile: profile, first: first, second: second} do
      view = navigate_to_booking_form(conn, profile, nil)

      # A single location is stated, so only the provider question is asked.
      refute has_element?(view, "[data-testid='location-option']")
      assert has_element?(view, "[data-testid='video-provider-field']")

      offered =
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.attribute("[data-testid='video-provider-option']", "data-video-integration-id")

      assert offered == [to_string(first.id), to_string(second.id)]
      assert :sys.get_state(view.pid).socket.assigns.selected_video_id == first.id
    end

    @tag :capture_log
    test "books the room on the provider the booker picked",
         %{conn: conn, profile: profile, second: second} do
      view = navigate_to_booking_form(conn, profile, nil)

      send(view.pid, {:step_event, :booking, :select_video_provider, to_string(second.id)})
      _drain = :sys.get_state(view.pid)

      html = submit(view, "teams@example.com")

      assert html =~ "Meeting Confirmed"
      assert html =~ "Video call (Teams)"

      assert [meeting] = Repo.all_by(MeetingSchema, attendee_email: "teams@example.com")
      assert meeting.location_option_id == "loc-video"
      assert meeting.video_integration_id == second.id
    end
  end

  # The location keeps naming the disconnected integration until the host
  # next edits the meeting type; the booking must not fail on it.
  describe "a video location whose integration the host has disconnected" do
    setup %{user: user} do
      gone = insert(:video_integration, user: user, name: "Zoom", is_active: true)

      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        name: "Consultation",
        is_active: true,
        locations: [office(), video_location(gone, id: "loc-video", label: "Video call")]
      )

      assert {:ok, :deleted} = Video.delete_integration(user.id, gone.id)

      :ok
    end

    @tag :capture_log
    test "still books it, without a provider to pick or a room to create",
         %{conn: conn, profile: profile} do
      view = navigate_to_booking_form(conn, profile, nil)

      send(view.pid, {:step_event, :booking, :select_location, "loc-video"})
      _drain = :sys.get_state(view.pid)

      refute has_element?(view, "[data-testid='video-provider-field']")
      assert submit(view, "gone@example.com") =~ "Meeting Confirmed"

      assert [meeting] = Repo.all_by(MeetingSchema, attendee_email: "gone@example.com")
      assert meeting.location_option_id == "loc-video"
      assert meeting.location_kind == "video"
      assert meeting.video_integration_id == nil
    end
  end

  describe "a meeting type offering a single location" do
    setup %{user: user} do
      meeting_type =
        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          name: "Office Visit",
          is_active: true,
          locations: [office()]
        )

      %{meeting_type: meeting_type}
    end

    @tag :capture_log
    test "asks nothing, and still records where the meeting is",
         %{conn: conn, profile: profile} do
      view = navigate_to_booking_form(conn, profile, nil)

      refute has_element?(view, "[data-testid='location-field']")

      assert submit(view, "single@example.com") =~ "Meeting Confirmed"

      assert [meeting] = Repo.all_by(MeetingSchema, attendee_email: "single@example.com")
      assert meeting.location == "Our office"
      assert meeting.location_kind == "in_person"
    end
  end

  describe "rescheduling a meeting" do
    setup %{user: user} do
      start = DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)

      book = fn locations, meeting_attrs ->
        meeting_type =
          insert(:meeting_type,
            user: user,
            duration_minutes: 30,
            name: "Consultation",
            is_active: true,
            locations: locations
          )

        insert(
          :meeting,
          Map.merge(
            %{
              organizer_user_id: user.id,
              meeting_type_id: meeting_type.id,
              attendee_name: "Booker",
              attendee_email: "rebook@example.com",
              attendee_timezone: "America/New_York",
              start_time: start,
              end_time: DateTime.add(start, 30, :minute),
              duration: 30,
              status: "confirmed"
            },
            meeting_attrs
          )
        )
      end

      %{book: book, original_start: start}
    end

    defp submit_reschedule(view, meeting, original_start) do
      submit(view, meeting.attendee_email)

      wait_until(fn ->
        Repo.get!(MeetingSchema, meeting.id).start_time != original_start
      end)

      Repo.get!(MeetingSchema, meeting.id)
    end

    defp booked_by_phone do
      %{
        location: "Phone call (+1 555 0100)",
        location_kind: "phone",
        location_option_id: "loc-call",
        attendee_phone: "+1 555 0100"
      }
    end

    @tag :capture_log
    test "the picker opens on the location the meeting was booked at",
         %{conn: conn, profile: profile, book: book} do
      meeting = book.([office(), call_me()], booked_by_phone())

      view = navigate_to_booking_form(conn, profile, nil, reschedule_meeting_uid: meeting.uid)
      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns.is_rescheduling
      assert has_element?(view, "[data-testid='location-field']")
      assert assigns.selected_location_id == "loc-call"
      assert assigns.location_phone == "+1 555 0100"
    end

    @tag :capture_log
    test "choosing another location moves the existing meeting there",
         %{conn: conn, profile: profile, book: book, original_start: original_start} do
      meeting = book.([office(), call_me()], booked_by_phone())

      view = navigate_to_booking_form(conn, profile, nil, reschedule_meeting_uid: meeting.uid)

      send(view.pid, {:step_event, :booking, :select_location, "loc-office"})
      _drain = :sys.get_state(view.pid)

      moved = submit_reschedule(view, meeting, original_start)

      assert moved.location == "Our office"
      assert moved.location_option_id == "loc-office"
      assert moved.location_kind == "in_person"
      assert moved.attendee_phone == nil

      # Moved, not rebooked.
      assert [_only] = Repo.all_by(MeetingSchema, attendee_email: "rebook@example.com")
    end

    @tag :capture_log
    test "a single location asks nothing and keeps the meeting where it was booked",
         %{conn: conn, profile: profile, book: book, original_start: original_start} do
      # The host has replaced the location this meeting was booked against.
      meeting =
        book.([office()], %{
          location: "The old office",
          location_kind: "in_person",
          location_option_id: "loc-old-office"
        })

      view = navigate_to_booking_form(conn, profile, nil, reschedule_meeting_uid: meeting.uid)

      refute has_element?(view, "[data-testid='location-field']")

      moved = submit_reschedule(view, meeting, original_start)

      assert moved.location == "The old office"
      assert moved.location_option_id == "loc-old-office"
    end
  end

  describe "rescheduling a meeting at a saved venue" do
    setup %{user: user} do
      start = DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)

      berlin =
        insert(:venue, user: user, name: "Berlin office", description: "Friedrichstrasse 1")

      munich = insert(:venue, user: user, name: "Munich office", description: "Marienplatz 2")
      # Dropped from the location since the meeting was booked there.
      hamburg = insert(:venue, user: user, name: "Hamburg office", description: "Jungfernstieg 3")

      option = in_person_location([berlin, munich], id: "loc-offices", label: "Our offices")

      meeting_type =
        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          name: "Consultation",
          is_active: true,
          locations: [option]
        )

      book = fn venue ->
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
          location: "#{venue.name} (#{venue.description})",
          location_kind: "in_person",
          location_option_id: "loc-offices",
          venue_id: venue.id
        )
      end

      %{book: book, original_start: start, berlin: berlin, munich: munich, hamburg: hamburg}
    end

    @tag :capture_log
    test "the picker opens on the meeting's venue, and a time-only move keeps it",
         %{conn: conn, profile: profile, book: book, munich: munich, original_start: start} do
      meeting = book.(munich)

      view = navigate_to_booking_form(conn, profile, nil, reschedule_meeting_uid: meeting.uid)

      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns.selected_venue_id == munich.id
      assert BookingLocation.submitted_venue_id(assigns) == munich.id

      moved = submit_reschedule(view, meeting, start)

      assert moved.venue_id == munich.id
      assert moved.location == "Munich office (Marienplatz 2)"
    end

    @tag :capture_log
    test "a venue no longer offered stays put when the booker only changes the time",
         %{conn: conn, profile: profile, book: book, berlin: berlin, hamburg: hamburg} = ctx do
      meeting = book.(hamburg)

      view = navigate_to_booking_form(conn, profile, nil, reschedule_meeting_uid: meeting.uid)

      # The picker falls back to the location's first venue, which the
      # booker never chose, so it must not move the meeting there.
      assert :sys.get_state(view.pid).socket.assigns.selected_venue_id == berlin.id

      moved = submit_reschedule(view, meeting, ctx.original_start)

      assert moved.venue_id == hamburg.id
      assert moved.location == "Hamburg office (Jungfernstieg 3)"
    end

    @tag :capture_log
    test "a venue the booker picks moves the meeting there",
         %{conn: conn, profile: profile, book: book, berlin: berlin, hamburg: hamburg} = ctx do
      meeting = book.(hamburg)

      view = navigate_to_booking_form(conn, profile, nil, reschedule_meeting_uid: meeting.uid)

      send(view.pid, {:step_event, :booking, :select_venue, to_string(berlin.id)})
      _drain = :sys.get_state(view.pid)

      moved = submit_reschedule(view, meeting, ctx.original_start)

      assert moved.venue_id == berlin.id
      assert moved.location == "Berlin office (Friedrichstrasse 1)"
    end
  end
end
