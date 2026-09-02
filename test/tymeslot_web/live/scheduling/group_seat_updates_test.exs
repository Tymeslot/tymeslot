defmodule TymeslotWeb.Live.Scheduling.GroupSeatUpdatesTest do
  @moduledoc """
  Live seat updates on open booking pages: a `{:seat_update, meeting_type_id}`
  message refreshes the displayed date's slots in place. The visitor's
  selection survives unless their slot filled up, in which case they bounce
  back to the schedule step with the slot-taken flash.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :scheduling
  @moduletag :live

  import Mox
  import Tymeslot.Factory
  import Tymeslot.BookingTestHelpers

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "seatwatcher",
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

    meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        name: "Watched Group",
        is_active: true,
        allow_guests: true,
        max_participants: 2
      )

    %{profile: profile, user: user, meeting_type: meeting_type}
  end

  @tag :capture_log
  test "seat_update refreshes counts and preserves the selection", %{
    conn: conn,
    profile: profile,
    meeting_type: meeting_type
  } do
    view = navigate_to_booking_form(conn, profile, nil)
    %{selected_time: selected_time} = :sys.get_state(view.pid).socket.assigns

    send(view.pid, {:seat_update, meeting_type.id})
    _drain = :sys.get_state(view.pid)

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.selected_time == selected_time
    assert assigns.current_state == :booking
  end

  @tag :capture_log
  test "a burst of seat_update broadcasts coalesces into a single trailing refresh", %{
    conn: conn,
    profile: profile,
    meeting_type: meeting_type
  } do
    view = navigate_to_booking_form(conn, profile, nil)
    # The first broadcast in a quiet period refreshes immediately, so the
    # burst that follows lands inside its debounce window.
    send(view.pid, {:seat_update, meeting_type.id})
    _drain = :sys.get_state(view.pid)

    send(view.pid, {:seat_update, meeting_type.id})
    send(view.pid, {:seat_update, meeting_type.id})
    send(view.pid, {:seat_update, meeting_type.id})
    state = :sys.get_state(view.pid)

    # Exactly one trailing refresh is scheduled behind the burst, not one per
    # message: three redundant timers would mean three uncached refetches
    # instead of one once the window elapses.
    assert Process.read_timer(state.socket.assigns.seat_update_timer_ref)
  end

  @tag :capture_log
  test "a passive refresh that fails to fetch leaves the slot list and the page quiet", %{
    conn: conn,
    profile: profile,
    meeting_type: meeting_type
  } do
    view = navigate_to_booking_form(conn, profile, nil)
    before = :sys.get_state(view.pid).socket.assigns

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:error, :all_calendars_unavailable}
    end)

    send(view.pid, {:seat_update, meeting_type.id})
    _drain = :sys.get_state(view.pid)

    assigns = :sys.get_state(view.pid).socket.assigns

    # The booker did nothing wrong: a background refresh failing must not
    # cost them the slot list they already had, nor blame them for it.
    assert assigns.available_slots == before.available_slots
    assert assigns.calendar_error == before.calendar_error
    refute render(view) =~ "No time slots could be loaded"
  end

  @tag :capture_log
  test "seat_update for a different meeting type is a no-op", %{
    conn: conn,
    profile: profile
  } do
    view = navigate_to_booking_form(conn, profile, nil)
    before = :sys.get_state(view.pid).socket.assigns

    send(view.pid, {:seat_update, -1})
    _drain = :sys.get_state(view.pid)

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.selected_time == before.selected_time
    assert assigns.available_slots == before.available_slots
  end

  @tag :capture_log
  test "seat_update that removes the selected slot bounces to the schedule step", %{
    conn: conn,
    profile: profile,
    meeting_type: meeting_type
  } do
    # Watcher selects the first slot and moves on to the booking form.
    watcher = navigate_to_booking_form(conn, profile, nil)

    # A rival booking fills the slot completely: capacity 2, booker plus one guest.
    rival = navigate_to_booking_form(build_conn(), profile, nil)
    send(rival.pid, {:step_event, :booking, :toggle_guests, nil})
    send(rival.pid, {:step_event, :booking, :add_guest, "companion@example.com"})

    rival
    |> form("form[phx-submit='submit']", %{
      "booking" => %{"name" => "Rival", "email" => "rival@example.com", "message" => ""}
    })
    |> render_submit()

    wait_until(fn -> render(rival) =~ "rival@example.com" end)

    # The domain layer broadcast this on booking; deliver it deterministically.
    send(watcher.pid, {:seat_update, meeting_type.id})
    _drain = :sys.get_state(watcher.pid)

    assigns = :sys.get_state(watcher.pid).socket.assigns
    assert assigns.current_state == :schedule
    assert assigns.selected_time == nil
    assert render(watcher) =~ "This time slot is no longer available"
  end
end
