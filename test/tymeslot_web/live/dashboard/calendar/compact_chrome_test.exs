defmodule TymeslotWeb.Dashboard.Calendar.CompactChromeTest do
  @moduledoc """
  The chrome above the new calendar stays small so the grid takes the
  screen: a compact top bar, and no Up-next strip (the grid's now line and
  preview do its job). The old calendar keeps both.
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

  test "the new calendar has a compact top bar and no Up-next strip", %{conn: conn} do
    %{conn: conn, user: user} = owner(conn)
    upcoming_booking(user)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(lv, "#dashboard-top-nav[data-compact='true']")
    refute has_element?(lv, "[data-testid='up-next-strip']")
  end

  test "the old calendar keeps the full top bar and the Up-next strip", %{conn: conn} do
    %{conn: conn, user: user} = owner(conn, redesign_enabled: false)
    upcoming_booking(user)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(lv, "#dashboard-top-nav[data-compact='false']")
    assert has_element?(lv, "[data-testid='up-next-strip']")
  end
end
