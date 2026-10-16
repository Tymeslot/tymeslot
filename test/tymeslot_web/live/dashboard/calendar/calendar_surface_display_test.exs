defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceDisplayTest do
  @moduledoc """
  The new calendar's display options: comfortable or compact density, and
  whether the hours before 07:00 fold into one strip. Each is saved and sent
  to the canvas hook to redraw.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries

  defp open_display_options(lv),
    do: lv |> element("#calendar-display-options > button") |> render_click()

  test "compact density is saved and sent to the canvas", %{conn: conn} do
    %{conn: conn, user: user} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    open_display_options(lv)
    lv |> element("#calendar-density-compact") |> render_click()

    assert_push_event(lv, "calendar:settings", %{density: "compact"})
    assert CalendarPreferencesQueries.get_or_create(user.id).density == "compact"
    assert has_element?(lv, "#calendar-density-compact[aria-pressed='true']")
  end

  test "unfolding the night is saved and sent to the canvas", %{conn: conn} do
    %{conn: conn, user: user} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    open_display_options(lv)
    lv |> element("#calendar-fold-night") |> render_click()

    assert_push_event(lv, "calendar:settings", %{fold_night: false})
    refute CalendarPreferencesQueries.get_or_create(user.id).fold_night
  end

  test "stored choices reach the canvas on its first request", %{conn: conn} do
    %{conn: conn} = owner(conn, preferences: [density: "compact", fold_night: false])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv |> element("#calendar-canvas") |> render_hook("calendar:ready", %{})

    assert_reply(lv, %{settings: %{density: "compact", fold_night: false}})
  end
end
