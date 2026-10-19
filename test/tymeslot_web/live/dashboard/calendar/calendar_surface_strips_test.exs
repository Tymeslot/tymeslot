defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceStripsTest do
  @moduledoc """
  The strips above the new calendar, as on the old one: the setup checklist
  and the Up next strip, which the agenda tick keeps current. Up next is
  hidden on phones on the new surface only.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.Factory
  import TymeslotWeb.CalendarSurfaceHelpers

  # The agenda behind the Up next strip reads the real clock, not the frozen
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

  test "the new calendar shows the next booking above the grid, hidden on phones", %{
    conn: conn
  } do
    %{conn: conn, user: user} = owner(conn)
    upcoming_booking(user)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(lv, "[data-testid='up-next-strip']", "Strategy sync")

    assert has_element?(
             lv,
             "#calendar-up-next[class~='max-sm:hidden'] [data-testid='up-next-strip']"
           )

    assert has_element?(lv, "#calendar-surface")
  end

  test "the old calendar keeps Up next at every width", %{conn: conn} do
    %{conn: conn, user: user} = owner(conn, redesign_enabled: false)
    upcoming_booking(user)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(lv, "#calendar-up-next [data-testid='up-next-strip']")
    refute has_element?(lv, "#calendar-up-next[class~='max-sm:hidden']")
  end

  test "the agenda tick brings in a booking made after the calendar opened", %{conn: conn} do
    %{conn: conn, user: user} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    refute has_element?(lv, "[data-testid='up-next-strip']")

    upcoming_booking(user)
    send(lv.pid, :agenda_tick)

    assert has_element?(lv, "[data-testid='up-next-strip']", "Strategy sync")
  end

  test "nothing upcoming, no strip", %{conn: conn} do
    %{conn: conn} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    refute has_element?(lv, "#calendar-up-next")
  end

  test "the setup checklist shows above the new calendar, with the tour's anchor", %{
    conn: conn
  } do
    %{conn: conn} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(lv, "[data-testid='onboarding-checklist']")
    assert has_element?(lv, "[data-tour='quick-actions']")
  end

  test "switching to the new calendar keeps the strip", %{conn: conn} do
    %{conn: conn, user: user} = owner(conn, redesign_enabled: false)
    upcoming_booking(user)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    render_hook(lv, "calendar:switch_surface", %{"enabled" => true})

    assert has_element?(lv, "#calendar-surface")
    assert has_element?(lv, "[data-testid='up-next-strip']", "Strategy sync")
  end
end
