defmodule TymeslotWeb.Dashboard.Calendar.CompactChromeTest do
  @moduledoc """
  The chrome above the new calendar stays small so the grid takes the
  screen: a compact top bar with no padding around its row, no Up-next strip
  (the grid's now line and preview do its job) and no "Finish setting up"
  strip (the overview keeps the checklist). The old calendar keeps all three.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.Factory
  import TymeslotWeb.CalendarSurfaceHelpers

  # The agenda behind the Up-next strip reads the real clock, not the frozen
  # one, so the booking is placed an hour after the real now.
  defp upcoming_booking(user) do
    start_time = DateTime.add(DateTime.utc_now(), 3600, :second)

    insert(:meeting,
      organizer_user: user,
      organizer_email: user.email,
      title: "Strategy sync",
      attendee_name: "Grace Hopper",
      start_time: start_time,
      end_time: DateTime.add(start_time, 1800, :second),
      status: "confirmed"
    )
  end

  test "the new calendar has a compact top bar and neither strip above the grid", %{conn: conn} do
    %{conn: conn, user: user} = owner(conn)
    upcoming_booking(user)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(lv, "#dashboard-top-nav[data-compact='true'] nav.brand-nav-compact")
    assert has_element?(lv, "#dashboard-top-nav[data-compact='true'] .h-11")
    refute has_element?(lv, "[data-testid='up-next-strip']")
    refute has_element?(lv, "[data-testid='onboarding-checklist']")
  end

  # The agenda feeds only the Up-next strip here, so the new surface neither
  # queries it on navigation nor keeps its minute timer.
  test "the new calendar loads no agenda and keeps no agenda timer", %{conn: conn} do
    %{conn: conn, user: user} = owner(conn)
    upcoming_booking(user)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("#calendar-next") |> render_click()
    send(lv.pid, :agenda_tick)
    _html = render(lv)

    assert %{agenda: nil, agenda_tick_ref: nil} = live_assigns(lv)
  end

  test "switching back to the old calendar loads the agenda and starts its timer", %{conn: conn} do
    %{conn: conn, user: user} = owner(conn)
    upcoming_booking(user)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    render_hook(lv, "calendar:switch_surface", %{"enabled" => false})

    assert %{agenda: %{next: %{}}, agenda_tick_ref: ref} = live_assigns(lv)
    assert is_reference(ref)
    assert has_element?(lv, "[data-testid='up-next-strip']")
  end

  defp live_assigns(lv), do: :sys.get_state(lv.pid).socket.assigns

  test "the old calendar keeps the full top bar and the Up-next strip", %{conn: conn} do
    %{conn: conn, user: user} = owner(conn, redesign_enabled: false)
    upcoming_booking(user)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(lv, "#dashboard-top-nav[data-compact='false']")
    refute has_element?(lv, "#dashboard-top-nav nav.brand-nav-compact")
    assert has_element?(lv, "[data-testid='up-next-strip']")
    assert has_element?(lv, "[data-testid='onboarding-checklist']")
  end
end
