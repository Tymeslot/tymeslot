defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceWeekNumbersTest do
  @moduledoc """
  The mini months the server draws (the rail, the toolbar's date picker and
  the phone's date sheet) show each row's ISO week when "Show week numbers"
  is on, numbered by the row's Monday whichever day the week starts on.
  The canvas draws its own (see `render.test.js`, `render_month.test.js`).
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers

  defp canvas(lv, event, params),
    do: lv |> element("#calendar-canvas") |> render_hook(event, params)

  defp numbers(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.find(".cal-weeknum")
    |> Enum.map(&(&1 |> Floki.text() |> String.trim()))
  end

  test "off by default: the rail's month has no week column", %{conn: conn} do
    %{conn: conn} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    refute has_element?(lv, "#calendar-rail-month .cal-weeknum")
  end

  test "on: the rail's month numbers each of its six rows", %{conn: conn} do
    %{conn: conn} = owner(conn, preferences: [show_week_numbers: true])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert numbers(lv, "#calendar-rail-month") == ~w(40 41 42 43 44 45)
    assert has_element?(lv, "#calendar-rail-month .cal-weeknum[role='img'][aria-label='Week 42']")
  end

  test "a Sunday week start keeps the Monday's number", %{conn: conn} do
    %{conn: conn} =
      owner(conn, preferences: [show_week_numbers: true, week_start_day: "sunday"])

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert numbers(lv, "#calendar-rail-month") == ~w(40 41 42 43 44 45)
  end

  test "switching them on in display options shows them at once", %{conn: conn} do
    %{conn: conn} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv |> element("#calendar-display-options > button") |> render_click()
    lv |> element("#calendar-week-numbers") |> render_click()

    assert numbers(lv, "#calendar-rail-month") == ~w(40 41 42 43 44 45)
  end

  test "the toolbar's date picker and the phone's date sheet show them too", %{conn: conn} do
    %{conn: conn} = owner(conn, preferences: [show_week_numbers: true])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv |> element("#calendar-date-picker > button") |> render_click()
    assert numbers(lv, "#calendar-picker-month") == ~w(40 41 42 43 44 45)

    canvas(lv, "calendar:toggle_menu", %{"menu" => "date_sheet"})
    assert numbers(lv, "#calendar-sheet-month") == ~w(40 41 42 43 44 45)
  end
end
