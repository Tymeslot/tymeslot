defmodule TymeslotWeb.Dashboard.CalendarRoutingTest do
  @moduledoc """
  Calendar messages reach whichever calendar is on screen: a discarded sync
  ends the old calendar's "Syncing" banner without its fallback timer, and
  the new calendar ignores messages only the old one handles.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers

  # A message to the LiveView becomes a component update, itself a message
  # queued behind it: the first render lets it through, the second shows it.
  defp settled(lv) do
    render(lv)
    render(lv)
  end

  test "a discarded sync ends the old calendar's syncing banner", %{conn: conn} do
    %{conn: conn, user: user, integration: integration} = owner(conn, redesign_enabled: false)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    assert settled(lv) =~ "Syncing calendars"

    send(lv.pid, {:calendar_sync_failed, user.id, integration.id})

    refute settled(lv) =~ "Syncing calendars"
  end

  test "the new calendar ignores what only the old one handles", %{conn: conn} do
    %{conn: conn} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    settled(lv)

    send(lv.pid, {:ics_import_progress, 3})
    settled(lv)

    refute_push_event(lv, "calendar:period", %{}, 100)
  end
end
