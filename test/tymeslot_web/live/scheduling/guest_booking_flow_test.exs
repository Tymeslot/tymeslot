defmodule TymeslotWeb.Live.Scheduling.GuestBookingFlowTest do
  @moduledoc """
  End-to-end integration test for the guest booking flow, walked on every
  theme in `TymeslotWeb.ThemeTestMatrix`.

  Exercises the full booker journey when a meeting type has `allow_guests: true`:

    * The "Add guests" toggle is visible and reveals the guest input.
    * Adding a valid guest email adds it to the chip list.
    * Adding a duplicate shows the "already added" error.
    * Adding the booker's own email shows the self-email error.
    * Adding an invalid format shows the format error.
    * Removing a chip removes the guest from the list.
    * Submitting the booking persists the guests server-side
      (verified via `Tymeslot.Meetings.Guests.list_for_meeting/1`).
    * The "Schedule another" confirmation action resets the guest list.
    * When `allow_guests: false`, the toggle is absent.

  Events are driven through the parent LiveView's `{:step_event, step, ...}`
  message path, under the step on show (`form_event/3`: the booking step on
  the classic journey, the schedule screen on Paper's), the same path the
  step holding the details form uses when it relays guest-field events from
  the LiveComponent to the root LiveView. This avoids fragility around
  LiveComponent targeting in tests while exercising exactly the same code
  paths the browser does.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :scheduling
  @moduletag :live

  import Mox
  import Tymeslot.Factory
  import Tymeslot.BookingTestHelpers

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias TymeslotWeb.ThemeTestMatrix

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
        booking_theme: Map.fetch!(tags, :theme_id),
        timezone: "America/New_York"
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_before_minutes: 0,
        buffer_after_minutes: 0
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

  # A details-form event, sent under the step on show: the booking step on
  # the classic journey, the schedule screen that holds the form on Paper's.
  defp form_event(view, event, data) do
    step = :sys.get_state(view.pid).socket.assigns.current_state
    send(view.pid, {:step_event, step, event, data})
  end

  for theme <- ThemeTestMatrix.all() do
    describe "#{theme.name}: guest field — allow_guests: true" do
      @describetag theme_id: theme.id

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
        form_event(view, :toggle_guests, nil)
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

        form_event(view, :toggle_guests, nil)
        form_event(view, :add_guest, "guest@example.com")
        _drain = :sys.get_state(view.pid)

        html = render(view)
        assert html =~ "guest@example.com"
        assert has_element?(view, "[data-testid='guest-chip']")
      end

      @tag :capture_log
      test "adding two guests renders two chips", %{conn: conn, profile: profile} do
        view = navigate_to_booking_form(conn, profile, nil)

        form_event(view, :toggle_guests, nil)
        form_event(view, :add_guest, "alpha@example.com")
        form_event(view, :add_guest, "beta@example.com")
        _drain = :sys.get_state(view.pid)

        html = render(view)
        assert html =~ "alpha@example.com"
        assert html =~ "beta@example.com"
      end

      @tag :capture_log
      test "removing a guest chip removes it from the list", %{conn: conn, profile: profile} do
        view = navigate_to_booking_form(conn, profile, nil)

        form_event(view, :toggle_guests, nil)
        form_event(view, :add_guest, "keeper@example.com")
        form_event(view, :add_guest, "todelete@example.com")
        form_event(view, :remove_guest, "todelete@example.com")
        _drain = :sys.get_state(view.pid)

        html = render(view)
        assert html =~ "keeper@example.com"
        refute html =~ "todelete@example.com"
      end

      @tag :capture_log
      test "close button clears guests and collapses the field", %{conn: conn, profile: profile} do
        view = navigate_to_booking_form(conn, profile, nil)

        form_event(view, :toggle_guests, nil)
        form_event(view, :add_guest, "willclose@example.com")
        _drain = :sys.get_state(view.pid)

        # Open with one guest and a close control present.
        assert has_element?(view, "[data-testid='guest-close']")
        assert render(view) =~ "willclose@example.com"

        # Closing resets the list and returns to the collapsed "+ Add guests" CTA.
        form_event(view, :close_guests, nil)
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

        form_event(view, :toggle_guests, nil)
        form_event(view, :add_guest, "dupe@example.com")
        form_event(view, :add_guest, "dupe@example.com")
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
        form_event(view, :validate, %{"email" => "self@example.com"})
        form_event(view, :toggle_guests, nil)
        form_event(view, :add_guest, "self@example.com")
        _drain = :sys.get_state(view.pid)

        # The apostrophe is HTML-entity-encoded in the rendered output, so
        # match on the portion of the message that has no apostrophe.
        assert render(view) =~ "need to add your own email"
      end

      @tag :capture_log
      test "invalid email format shows format error", %{conn: conn, profile: profile} do
        view = navigate_to_booking_form(conn, profile, nil)

        form_event(view, :toggle_guests, nil)
        form_event(view, :add_guest, "not-an-email")
        _drain = :sys.get_state(view.pid)

        assert render(view) =~ "Enter a valid email address"
      end

      @tag :capture_log
      test "cap error shown when max_guests is reached", %{conn: conn, profile: profile} do
        view = navigate_to_booking_form(conn, profile, nil)

        form_event(view, :toggle_guests, nil)

        # Fill the list to the public page's default, the type setting none.
        Enum.each(1..Guests.default_booking_limit(), fn n ->
          form_event(view, :add_guest, "guest#{n}@example.com")
        end)

        # One more should trigger the cap error.
        form_event(view, :add_guest, "overflow@example.com")
        _drain = :sys.get_state(view.pid)

        assert render(view) =~ "You can add up to #{Guests.default_booking_limit()} guests"
      end

      @tag :capture_log
      test "guests are persisted on the created meeting", %{conn: conn, profile: profile} do
        view = navigate_to_booking_form(conn, profile, nil)

        form_event(view, :toggle_guests, nil)
        form_event(view, :add_guest, "invited1@example.com")
        form_event(view, :add_guest, "invited2@example.com")

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
        assert has_element?(view, "[data-testid='confirmation-heading']")

        # The confirmation must acknowledge the invited guests back to the booker.
        assert html =~ "invited1@example.com"
        assert html =~ "invited2@example.com"

        # Read the created meeting back and verify guests are stored.
        [meeting] = Repo.all_by(MeetingSchema, attendee_email: "sender@example.com")

        guest_emails =
          meeting.id
          |> Guests.list_for_meeting()
          |> Enum.map(& &1.email)
          |> Enum.sort()

        assert guest_emails == ["invited1@example.com", "invited2@example.com"]
      end

      @tag :capture_log
      test "schedule_another resets the guest list", %{conn: conn, profile: profile} do
        view = navigate_to_booking_form(conn, profile, nil)

        form_event(view, :toggle_guests, nil)
        form_event(view, :add_guest, "willbecleared@example.com")

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

    describe "#{theme.name}: guest field — allow_guests: false" do
      @describetag theme_id: theme.id

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

    describe "#{theme.name}: guest field — the meeting type's guest limit" do
      @describetag theme_id: theme.id

      setup %{user: user} do
        meeting_type =
          insert(:meeting_type,
            user: user,
            duration_minutes: 30,
            name: "Two Guests Each",
            is_active: true,
            allow_guests: true,
            max_guests_per_booking: 2
          )

        %{meeting_type: meeting_type}
      end

      @tag :capture_log
      test "a booking brings no more guests than the meeting type allows", %{
        conn: conn,
        profile: profile
      } do
        view = navigate_to_booking_form(conn, profile, nil)

        form_event(view, :toggle_guests, nil)

        for email <- ["first@example.com", "second@example.com", "third@example.com"] do
          form_event(view, :add_guest, email)
        end

        _drain = :sys.get_state(view.pid)

        assert render(view) =~ "You can add up to 2 guests"

        view
        |> form("form[phx-submit='submit']", %{
          "booking" => %{
            "name" => "Limited Booker",
            "email" => "limited@example.com",
            "message" => ""
          }
        })
        |> render_submit()

        _drain = :sys.get_state(view.pid)

        assert has_element?(view, "[data-testid='confirmation-heading']")
        [meeting] = Repo.all_by(MeetingSchema, attendee_email: "limited@example.com")

        guest_emails =
          meeting.id
          |> Guests.list_for_meeting()
          |> Enum.map(& &1.email)
          |> Enum.sort()

        assert guest_emails == ["first@example.com", "second@example.com"]
      end
    end

    describe "#{theme.name}: guest field — a limit above the booking page's default" do
      @describetag theme_id: theme.id

      setup %{user: user} do
        limit = Guests.default_booking_limit() + 1

        meeting_type =
          insert(:meeting_type,
            user: user,
            duration_minutes: 30,
            name: "Bring The Team",
            is_active: true,
            allow_guests: true,
            max_guests_per_booking: limit
          )

        %{meeting_type: meeting_type, limit: limit}
      end

      @tag :capture_log
      test "a booker can bring every guest the meeting type allows", %{
        conn: conn,
        profile: profile,
        limit: limit
      } do
        view = navigate_to_booking_form(conn, profile, nil)

        form_event(view, :toggle_guests, nil)

        invited = for n <- 1..limit, do: "guest#{n}@example.com"
        Enum.each(invited, &form_event(view, :add_guest, &1))

        _drain = :sys.get_state(view.pid)

        view
        |> form("form[phx-submit='submit']", %{
          "booking" => %{
            "name" => "Team Booker",
            "email" => "team@example.com",
            "message" => ""
          }
        })
        |> render_submit()

        _drain = :sys.get_state(view.pid)

        assert has_element?(view, "[data-testid='confirmation-heading']")
        [meeting] = Repo.all_by(MeetingSchema, attendee_email: "team@example.com")

        assert meeting.id |> Guests.list_for_meeting() |> Enum.map(& &1.email) |> Enum.sort() ==
                 Enum.sort(invited)
      end
    end
  end

  for theme <- ThemeTestMatrix.all() do
    describe "#{theme.name}: guest field — group meeting type seat cap" do
      @describetag theme_id: theme.id

      setup %{user: user} do
        meeting_type =
          insert(:meeting_type,
            user: user,
            duration_minutes: 30,
            name: "Group Session",
            is_active: true,
            allow_guests: true,
            max_participants: 3,
            last_spots_threshold: 3
          )

        %{meeting_type: meeting_type}
      end

      @tag :capture_log
      test "cap is reduced to the seats left beyond the booker's own", %{
        conn: conn,
        profile: profile
      } do
        view = navigate_to_booking_form(conn, profile, nil)

        # Capacity 3, empty slot: the booker takes one seat, so at most 2 guests.
        # The counter only renders once the guest field is open.
        form_event(view, :toggle_guests, nil)
        _drain = :sys.get_state(view.pid)
        assert render(view) =~ "0/2"

        form_event(view, :add_guest, "one@example.com")
        form_event(view, :add_guest, "two@example.com")
        form_event(view, :add_guest, "three@example.com")
        _drain = :sys.get_state(view.pid)

        html = render(view)
        assert html =~ "You can add up to 2 guests"
        assert html =~ "2/2"
        refute html =~ "three@example.com"
      end

      @tag :capture_log
      test "guest field is hidden when only the last seat remains", %{
        conn: conn,
        profile: profile
      } do
        # First booker takes 2 of 3 seats (themselves plus one guest).
        first = navigate_to_booking_form(conn, profile, nil)
        form_event(first, :toggle_guests, nil)
        form_event(first, :add_guest, "plusone@example.com")

        first
        |> form("form[phx-submit='submit']", %{
          "booking" => %{
            "name" => "First Booker",
            "email" => "first@example.com",
            "message" => ""
          }
        })
        |> render_submit()

        wait_until(fn -> render(first) =~ "first@example.com" end)

        # Second booker sees 1 seat left on that slot — no guest field at all.
        second = navigate_to_booking_form(build_conn(), profile, nil)

        refute has_element?(second, "[data-testid='guest-toggle']")
        refute has_element?(second, "[data-testid='guest-field']")
      end
    end

    describe "#{theme.name}: guest field — group meeting type with the count hidden" do
      @describetag theme_id: theme.id

      setup %{user: user} do
        # No last-spots threshold: the slot never shows its exact count.
        meeting_type =
          insert(:meeting_type,
            user: user,
            duration_minutes: 30,
            name: "Group Session",
            is_active: true,
            allow_guests: true,
            max_participants: 3
          )

        %{meeting_type: meeting_type}
      end

      # The cap is seats_left - 1, so "0/2" would tell the visitor exactly
      # three spots remain on a slot that shows no count.
      @tag :capture_log
      test "the header shows guests added without the cap, which is still enforced", %{
        conn: conn,
        profile: profile
      } do
        view = navigate_to_booking_form(conn, profile, nil)

        form_event(view, :toggle_guests, nil)
        _drain = :sys.get_state(view.pid)
        assert view |> element("[data-testid='guest-count']") |> render() =~ ~r/>\s*0\s*</

        form_event(view, :add_guest, "one@example.com")
        form_event(view, :add_guest, "two@example.com")
        _drain = :sys.get_state(view.pid)

        # At the cap the add input stays, since hiding it would give the count away too.
        assert view |> element("[data-testid='guest-count']") |> render() =~ ~r/>\s*2\s*</
        assert has_element?(view, "[data-testid='guest-input']")

        form_event(view, :add_guest, "three@example.com")
        _drain = :sys.get_state(view.pid)

        html = render(view)
        assert html =~ "You can add up to 2 guests"
        refute html =~ "three@example.com"
      end
    end
  end
end
