defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceSwitchTest do
  @moduledoc """
  The per-user switch between the old calendar and the redesigned one: a
  "Try the new calendar" control in the old calendar's settings, a "Back to
  the old calendar" control in the new one's display options, and the choice
  remembered across visits.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries

  describe "from the old calendar" do
    setup %{conn: conn}, do: owner(conn, redesign_enabled: false)

    test "an organiser who never switched keeps the old grid", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      assert has_element?(lv, "#calendar-grid")
      refute has_element?(lv, "#calendar-surface")
    end

    test "Try the new calendar swaps the surface and remembers the choice", %{
      conn: conn,
      user: user
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv |> element("button[phx-click='toggle_settings']") |> render_click()
      lv |> element("#calendar-try-new") |> render_click()

      assert has_element?(lv, "#calendar-surface")
      refute has_element?(lv, "#calendar-grid")
      assert CalendarPreferencesQueries.get_or_create(user.id).redesign_enabled
    end
  end

  describe "from the new calendar" do
    setup %{conn: conn}, do: owner(conn)

    test "Back to the old calendar swaps back, and the next visit opens the old grid", %{
      conn: conn,
      user: user
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv |> element("#calendar-display-options > button") |> render_click()
      lv |> element("#calendar-back-to-old") |> render_click()

      assert has_element?(lv, "#calendar-grid")
      refute CalendarPreferencesQueries.get_or_create(user.id).redesign_enabled

      {:ok, again, _html} = live(conn, ~p"/dashboard/calendar")
      assert has_element?(again, "#calendar-grid")
    end
  end
end
