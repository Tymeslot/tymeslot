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
  alias Tymeslot.Meetings.MeetingListQueries
  alias Tymeslot.MeetingTypes.LocationOption
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

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
      details: "12 High Street",
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

      assert render(view) =~ "12 High Street"
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
      assert MeetingListQueries.list_meetings_by_attendee_email("nophone@example.com") == []
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

      assert [meeting] = MeetingListQueries.list_meetings_by_attendee_email("phone@example.com")
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

      assert [meeting] = MeetingListQueries.list_meetings_by_attendee_email("default@example.com")
      assert meeting.location == "Our office (12 High Street)"
      assert meeting.location_option_id == "loc-office"
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

      assert [meeting] = MeetingListQueries.list_meetings_by_attendee_email("single@example.com")
      assert meeting.location == "Our office (12 High Street)"
      assert meeting.location_kind == "in_person"
    end
  end
end
