defmodule TymeslotWeb.Dashboard.Calendar.LastViewTest do
  @moduledoc """
  The calendar opens on the view the organiser last chose on a desktop:
  Day, Week, Month or Agenda. Three days, anything chosen on a phone and
  the view a link opened with are never remembered.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries

  defp canvas(lv, event, params),
    do: lv |> element("#calendar-canvas") |> render_hook(event, params)

  defp goto(lv, view, date) do
    canvas(lv, "calendar:goto", %{"view" => view, "date" => date})
    assert_patch(lv, "/dashboard/calendar?view=#{view}&date=#{date}")
    render(lv)
  end

  defp default_view(user), do: CalendarPreferencesQueries.get_or_create(user.id).default_view

  test "a month chosen on a desktop is where the calendar opens next time", %{conn: conn} do
    %{conn: conn, user: user} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    goto(lv, "month", "2026-10-14")
    assert default_view(user) == "month"

    {:ok, again, _html} = live(conn, ~p"/dashboard/calendar")
    canvas(again, "calendar:ready", %{})
    assert_reply(again, %{view: "month"})
  end

  test "day and agenda are remembered too", %{conn: conn} do
    %{conn: conn, user: user} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    goto(lv, "day", "2026-10-15")
    assert default_view(user) == "day"

    goto(lv, "agenda", "2026-10-15")
    assert default_view(user) == "agenda"
  end

  test "three days on a desktop is never remembered", %{conn: conn} do
    %{conn: conn, user: user} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    goto(lv, "three_day", "2026-10-15")

    assert default_view(user) == "week"
  end

  test "a view chosen on a phone is never remembered", %{conn: conn} do
    %{conn: conn, user: user} = owner(conn)

    {:ok, lv, _html} =
      live(put_connect_params(conn, %{"viewport" => "phone"}), ~p"/dashboard/calendar")

    canvas(lv, "calendar:ready", %{"phone" => true})

    goto(lv, "day", "2026-10-15")
    goto(lv, "month", "2026-10-15")

    assert default_view(user) == "week"
  end

  test "the view a link opens with is not remembered", %{conn: conn} do
    %{conn: conn, user: user} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=month&date=2026-10-14")
    render(lv)

    assert default_view(user) == "week"
  end

  test "widening a phone is not a choice of view", %{conn: conn} do
    %{conn: conn, user: user} = owner(conn, preferences: [default_view: "agenda"])

    {:ok, lv, _html} =
      live(
        put_connect_params(conn, %{"viewport" => "phone"}),
        ~p"/dashboard/calendar?view=week&date=2026-10-14"
      )

    canvas(lv, "calendar:ready", %{"phone" => true})
    # Wide again: the three days become the week, which nobody chose.
    canvas(lv, "calendar:viewport", %{"phone" => false})
    render(lv)

    assert default_view(user) == "agenda"
  end
end
