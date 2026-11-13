defmodule TymeslotWeb.Dashboard.Calendar.CompactChromeTest do
  @moduledoc """
  The chrome above the calendar stays small so the grid takes the screen: a
  compact top bar with no padding around its row. The calendar carries the
  Up next strip and the setup checklist (see `CalendarSurfaceStripsTest`).
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers

  test "the calendar has a compact top bar", %{conn: conn} do
    %{conn: conn} = owner(conn)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(lv, "#dashboard-top-nav[data-compact='true'] nav.brand-nav-compact")
    assert has_element?(lv, "#dashboard-top-nav[data-compact='true'] .h-11")
  end
end
