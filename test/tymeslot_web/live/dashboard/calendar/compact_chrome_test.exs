defmodule TymeslotWeb.Dashboard.Calendar.CompactChromeTest do
  @moduledoc """
  The chrome above the new calendar stays small so the grid takes the
  screen: a compact top bar with no padding around its row. The old
  calendar keeps the full top bar. Both calendars carry the Up next strip
  and the setup checklist (see `CalendarSurfaceStripsTest`).
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

  test "the new calendar has a compact top bar", %{conn: conn} do
    %{conn: conn, user: user} = owner(conn)
    upcoming_booking(user)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(lv, "#dashboard-top-nav[data-compact='true'] nav.brand-nav-compact")
    assert has_element?(lv, "#dashboard-top-nav[data-compact='true'] .h-11")
  end

  test "switching back to the old calendar shows the Up-next strip with the next booking", %{
    conn: conn
  } do
    %{conn: conn, user: user} = owner(conn)
    upcoming_booking(user)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    render_hook(lv, "calendar:switch_surface", %{"enabled" => false})
    send(lv.pid, :agenda_tick)

    assert has_element?(lv, "[data-testid='up-next-strip']", "Strategy sync")
  end

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
