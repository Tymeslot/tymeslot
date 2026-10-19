defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceMonthTest do
  @moduledoc """
  The month view on the server: its URL, title and steps, the window the
  hook draws it from, and the bookable layer it leaves unloaded.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Mox
  import TymeslotWeb.BookableLayerHelpers
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.CalendarMock

  setup %{conn: conn}, do: owner(conn)

  test "a month URL opens on that month, titled with it, stepping by a month", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=month&date=2026-10-14")

    assert lv |> element("#calendar-period-title") |> render() =~ "October 2026"
    assert has_element?(lv, "#calendar-prev[aria-label='Previous month']")
    assert has_element?(lv, "#calendar-next[aria-label='Next month']")
  end

  test "next from 31 January lands on the last day of February", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=month&date=2026-01-31")

    lv |> element("#calendar-next") |> render_click()

    assert_patch(lv, "/dashboard/calendar?view=month&date=2026-02-28")
  end

  test "the hook's first request gets the month's six weeks with a month's grid either side",
       %{conn: conn, integration: integration} do
    event(integration, "work", "Early September", ~U[2026-09-01 09:00:00Z])
    event(integration, "work", "Too far", ~U[2026-12-10 09:00:00Z])

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=month&date=2026-10-14")
    lv |> element("#calendar-canvas") |> render_hook("calendar:ready", %{})

    assert_reply(lv, %{
      view: "month",
      date: "2026-10-14",
      range: %{from: "2026-08-31", to: "2026-12-07"},
      events: events
    })

    titles = Enum.map(events, & &1.title)
    assert "Early September" in titles
    refute "Too far" in titles
  end

  describe "with a meeting type" do
    setup %{user: user} do
      open_days(user)
      %{intro: meeting_type(user)}
    end

    test "month view computes no bookable times, and the week brings them back", %{conn: conn} do
      test_pid = self()

      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to ->
        send(test_pid, :fetched)
        {:ok, []}
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=month&date=2026-10-14")
      render_async(lv)

      refute_push_event(lv, "calendar:bookable", _layer)
      refute_received :fetched

      lv |> element("#calendar-view-week") |> render_click()

      assert %{on: true} = await_bookable(lv, &on_day?(&1, "2026-10-15"))
    end
  end
end
