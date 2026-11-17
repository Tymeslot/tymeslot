defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceJourneyTest do
  @moduledoc """
  The organiser's journey through the calendar: read the week, step to the
  next week with the URL following, hide a calendar and see the filter chip
  that says so.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live
  @moduletag :integration

  import TymeslotWeb.CalendarSurfaceHelpers

  defp titles(events), do: Enum.map(events, & &1.title)

  test "read the week, step forward, hide a calendar and bring it back", %{conn: conn} do
    %{conn: conn, integration: integration} = owner(conn)
    event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
    event(integration, "family", "School run", ~U[2026-10-15 07:30:00Z])
    event(integration, "family", "Swimming", ~U[2026-10-22 16:00:00Z])

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    assert has_element?(lv, "#calendar-surface")

    # The canvas asks for its data and gets this week, from its calendars.
    lv |> element("#calendar-canvas") |> render_hook("calendar:ready", %{})
    assert_reply(lv, %{date: "2026-10-14", events: this_week})
    assert ["Design review", "School run"] -- titles(this_week) == []
    assert lv |> element("#calendar-period-title") |> render() =~ "October 2026"

    # Next week: the URL follows and the server sends that window.
    lv |> element("#calendar-next") |> render_click()
    assert_patch(lv, "/dashboard/calendar?view=week&date=2026-10-21")
    assert_push_event(lv, "calendar:events", %{date: "2026-10-21", events: next_week})
    assert "Swimming" in titles(next_week)

    # Hide Family: its events leave the grid.
    lv |> element("#calendar-rail [data-calendar-id='family']") |> render_click()
    assert_push_event(lv, "calendar:events", %{reset: true, events: filtered})
    refute "Swimming" in titles(filtered)

    # Collapse the rail: the hidden calendar is still announced.
    lv |> element("#calendar-rail-toggle") |> render_click()
    refute has_element?(lv, "#calendar-rail")
    assert has_element?(lv, "#calendar-filter-chip", "1 calendar hidden")

    # The chip's x brings Family back.
    lv |> element("#calendar-show-all") |> render_click()
    assert_push_event(lv, "calendar:events", %{reset: true, events: restored})
    assert "Swimming" in titles(restored)
    refute has_element?(lv, "#calendar-filter-chip")

    # A reload of the URL lands on the same week.
    {:ok, reloaded, _html} = live(conn, ~p"/dashboard/calendar?view=week&date=2026-10-21")
    assert has_element?(reloaded, "#calendar-surface")
    assert has_element?(reloaded, "#calendar-view-week[aria-pressed='true']")
  end
end
