defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceStripsTest do
  @moduledoc """
  The strips above the calendar: the setup checklist and the Up next strip,
  which the agenda tick keeps current. Up next is hidden on phones.
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

  test "the calendar shows the next booking above the grid, hidden on phones", %{
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

  test "the agenda tick brings in a booking made after the calendar opened", %{conn: conn} do
    %{conn: conn, user: user} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    refute has_element?(lv, "[data-testid='up-next-strip']")

    upcoming_booking(user)
    send(lv.pid, :agenda_tick)

    assert has_element?(lv, "[data-testid='up-next-strip']", "Strategy sync")
  end

  # The strip appearing must not touch the surface's markup: the grid keeps
  # its scroll offset and any drag in progress.
  test "the agenda tick adds the strip without changing the surface's markup", %{conn: conn} do
    %{conn: conn, user: user} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("#calendar-next") |> render_click()
    before = lv |> element("#calendar-surface") |> render()

    upcoming_booking(user)
    send(lv.pid, :agenda_tick)

    assert has_element?(lv, "[data-testid='up-next-strip']", "Strategy sync")
    assert lv |> element("#calendar-surface") |> render() == before
  end

  test "nothing upcoming, no strip", %{conn: conn} do
    %{conn: conn} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    refute has_element?(lv, "#calendar-up-next")
  end

  test "the setup checklist shows above the calendar, with the tour's anchor", %{
    conn: conn
  } do
    %{conn: conn} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(lv, "[data-testid='onboarding-checklist']")
    assert has_element?(lv, "[data-tour='quick-actions']")
  end
end
