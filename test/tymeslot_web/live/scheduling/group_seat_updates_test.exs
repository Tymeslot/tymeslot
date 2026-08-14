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
