defmodule TymeslotWeb.Live.Scheduling.GuestBookingFlowTest do
  @moduledoc """
  End-to-end integration test for the guest booking flow on the Quill theme.

  Exercises the full booker journey when a meeting type has `allow_guests: true`:

    * The "Add guests" toggle is visible and reveals the guest input.
    * Adding a valid guest email adds it to the chip list.
    * Adding a duplicate shows the "already added" error.
    * Adding the booker's own email shows the self-email error.
    * Adding an invalid format shows the format error.
    * Removing a chip removes the guest from the list.
    * Submitting the booking persists the guests server-side
      (verified via `Tymeslot.Meetings.list_meeting_guests/1`).
    * The "Schedule another" confirmation action resets the guest list.
    * When `allow_guests: false`, the toggle is absent.

  Events are driven through the parent LiveView's `{:step_event, :booking, ...}`
  message path — the same path that `BookingComponent` uses when it relays
  guest-field events from the LiveComponent to the root LiveView. This avoids
  fragility around LiveComponent targeting in tests while exercising exactly
  the same code paths the browser does.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :scheduling
  @moduletag :live

  import Mox
  import Tymeslot.Factory
  import Tymeslot.BookingTestHelpers

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingQueries
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
        username: "guestbooker",
        booking_theme: "1",
        timezone: "America/New_York",
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_minutes: 0
      )

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        profile: profile,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    insert(:calendar_integration, user: user, is_active: true)

    %{profile: profile, user: user}
  end

  describe "guest field — allow_guests: true" do
    setup %{user: user} do
      meeting_type =
        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          name: "Guests Welcome",
          is_active: true,
          allow_guests: true
        )

      %{meeting_type: meeting_type}
    end

    @tag :capture_log
    test "toggle shows the guest input area", %{conn: conn, profile: profile} do
      view = navigate_to_booking_form(conn, profile, nil)

      # Before toggling: the "Add guests" button is visible.
      assert has_element?(view, "[data-testid='guest-toggle']")
      refute has_element?(view, "[data-testid='guest-input']")

      # Send the toggle_guests event (same path as the LiveComponent click).
      send(view.pid, {:step_event, :booking, :toggle_guests, nil})
      _drain = :sys.get_state(view.pid)

      # After toggling: the input area replaces the toggle button.
      assert has_element?(view, "[data-testid='guest-input']")
      refute has_element?(view, "[data-testid='guest-toggle']")

      # The add form opts out of native browser validation, so an invalid
      # email reaches the server and surfaces the inline error instead of the
      # browser silently blocking the submit.
      assert view |> element("form.guest-add") |> render() =~ "novalidate"
    end

    @tag :capture_log
    test "adding a valid guest email adds a chip", %{conn: conn, profile: profile} do
      view = navigate_to_booking_form(conn, profile, nil)

      send(view.pid, {:step_event, :booking, :toggle_guests, nil})
      send(view.pid, {:step_event, :booking, :add_guest, "guest@example.com"})
      _drain = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "guest@example.com"
      assert has_element?(view, "[data-testid='guest-chip']")
    end

    @tag :capture_log
    test "adding two guests renders two chips", %{conn: conn, profile: profile} do
      view = navigate_to_booking_form(conn, profile, nil)

      send(view.pid, {:step_event, :booking, :toggle_guests, nil})
      send(view.pid, {:step_event, :booking, :add_guest, "alpha@example.com"})
      send(view.pid, {:step_event, :booking, :add_guest, "beta@example.com"})
      _drain = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "alpha@example.com"
      assert html =~ "beta@example.com"
    end

    @tag :capture_log
    test "removing a guest chip removes it from the list", %{conn: conn, profile: profile} do
      view = navigate_to_booking_form(conn, profile, nil)

      send(view.pid, {:step_event, :booking, :toggle_guests, nil})
      send(view.pid, {:step_event, :booking, :add_guest, "keeper@example.com"})
      send(view.pid, {:step_event, :booking, :add_guest, "todelete@example.com"})
      send(view.pid, {:step_event, :booking, :remove_guest, "todelete@example.com"})
      _drain = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "keeper@example.com"
      refute html =~ "todelete@example.com"
    end

    @tag :capture_log
    test "close button clears guests and collapses the field", %{conn: conn, profile: profile} do
      view = navigate_to_booking_form(conn, profile, nil)

      send(view.pid, {:step_event, :booking, :toggle_guests, nil})
      send(view.pid, {:step_event, :booking, :add_guest, "willclose@example.com"})
      _drain = :sys.get_state(view.pid)

      # Open with one guest and a close control present.
      assert has_element?(view, "[data-testid='guest-close']")
      assert render(view) =~ "willclose@example.com"

      # Closing resets the list and returns to the collapsed "+ Add guests" CTA.
      send(view.pid, {:step_event, :booking, :close_guests, nil})
      _drain = :sys.get_state(view.pid)

      state = :sys.get_state(view.pid).socket.assigns
      assert state.guest_emails == []
      assert state.guests_open == false
      refute render(view) =~ "willclose@example.com"
      assert has_element?(view, "[data-testid='guest-toggle']")
    end

    @tag :capture_log
    test "duplicate email shows 'already added' error", %{conn: conn, profile: profile} do
      view = navigate_to_booking_form(conn, profile, nil)

      send(view.pid, {:step_event, :booking, :toggle_guests, nil})
      send(view.pid, {:step_event, :booking, :add_guest, "dupe@example.com"})
      send(view.pid, {:step_event, :booking, :add_guest, "dupe@example.com"})
      _drain = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "has already been added"
      # Only one chip rendered.
      assert [_single] =
               html
               |> Floki.parse_document!()
               |> Floki.find("[data-testid='guest-chip']")
    end

    @tag :capture_log
    test "adding the booker's own email shows self-email error", %{
      conn: conn,
      profile: profile
    } do
      view = navigate_to_booking_form(conn, profile, nil)

      # Seed the form with the booker's email so GuestBooking.primary_email?/2 can match it.
      send(view.pid, {:step_event, :booking, :validate, %{"email" => "self@example.com"}})
      send(view.pid, {:step_event, :booking, :toggle_guests, nil})
      send(view.pid, {:step_event, :booking, :add_guest, "self@example.com"})
      _drain = :sys.get_state(view.pid)

      # The apostrophe is HTML-entity-encoded in the rendered output, so
      # match on the portion of the message that has no apostrophe.
      assert render(view) =~ "need to add your own email"
    end

    @tag :capture_log
    test "invalid email format shows format error", %{conn: conn, profile: profile} do
      view = navigate_to_booking_form(conn, profile, nil)

      send(view.pid, {:step_event, :booking, :toggle_guests, nil})
      send(view.pid, {:step_event, :booking, :add_guest, "not-an-email"})
      _drain = :sys.get_state(view.pid)

      assert render(view) =~ "Enter a valid email address"
    end

    @tag :capture_log
    test "cap error shown when max_guests is reached", %{conn: conn, profile: profile} do
      view = navigate_to_booking_form(conn, profile, nil)

      send(view.pid, {:step_event, :booking, :toggle_guests, nil})

      # Fill the list to the maximum.
      Enum.each(1..Guests.max_guests(), fn n ->
        send(view.pid, {:step_event, :booking, :add_guest, "guest#{n}@example.com"})
      end)

      # One more should trigger the cap error.
      send(view.pid, {:step_event, :booking, :add_guest, "overflow@example.com"})
      _drain = :sys.get_state(view.pid)

      assert render(view) =~ "You can add up to #{Guests.max_guests()} guests"
    end

    @tag :capture_log
    test "guests are persisted on the created meeting", %{conn: conn, profile: profile} do
      view = navigate_to_booking_form(conn, profile, nil)

      send(view.pid, {:step_event, :booking, :toggle_guests, nil})
      send(view.pid, {:step_event, :booking, :add_guest, "invited1@example.com"})
      send(view.pid, {:step_event, :booking, :add_guest, "invited2@example.com"})

      view
      |> form("form[phx-submit='submit']", %{
        "booking" => %{
          "name" => "Guest Sender",
          "email" => "sender@example.com",
          "message" => ""
        }
      })
      |> render_submit()

      _drain = :sys.get_state(view.pid)

      # The confirmation page must be showing.
      html = render(view)
      assert html =~ "Meeting Confirmed" or html =~ "confirmed" or html =~ "Booking submitted"

      # The confirmation must acknowledge the invited guests back to the booker.
      assert html =~ "invited1@example.com"
      assert html =~ "invited2@example.com"

      # Read the created meeting back and verify guests are stored.
      [meeting] = MeetingQueries.list_meetings_by_attendee_email("sender@example.com")

      guest_emails =
        meeting.id
        |> Meetings.list_meeting_guests()
        |> Enum.map(& &1.email)
        |> Enum.sort()

      assert guest_emails == ["invited1@example.com", "invited2@example.com"]
    end

    @tag :capture_log
    test "schedule_another resets the guest list", %{conn: conn, profile: profile} do
      view = navigate_to_booking_form(conn, profile, nil)

      send(view.pid, {:step_event, :booking, :toggle_guests, nil})
      send(view.pid, {:step_event, :booking, :add_guest, "willbecleared@example.com"})

      view
      |> form("form[phx-submit='submit']", %{
        "booking" => %{
          "name" => "Reset Tester",
          "email" => "resetter@example.com",
          "message" => ""
        }
      })
      |> render_submit()

      _drain = :sys.get_state(view.pid)

      # Trigger "Schedule another" from the confirmation step.
      send(view.pid, {:step_event, :confirmation, :schedule_another, nil})
      _drain = :sys.get_state(view.pid)

      # The guest list must be empty and the toggle must be back.
      state = :sys.get_state(view.pid).socket.assigns
      assert state.guest_emails == []
      assert state.guests_open == false
    end
  end

  describe "guest field — allow_guests: false" do
    setup %{user: user} do
      meeting_type =
        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          name: "No Guests",
          is_active: true,
          allow_guests: false
        )

      %{meeting_type: meeting_type}
    end

    @tag :capture_log
    test "guest toggle is absent when allow_guests is false", %{conn: conn, profile: profile} do
      view = navigate_to_booking_form(conn, profile, nil)

      html = render(view)
      refute html =~ "Add guests"
      refute has_element?(view, "[data-testid='guest-toggle']")
      refute has_element?(view, "[data-testid='guest-input']")
    end
  end
end
