defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceDisplayTest do
  @moduledoc """
  The new calendar's display options, drawn once (`DisplayOptions`) for the
  toolbar and the Calendars sheet: comfortable or compact density, and
  whether the hours before 07:00 fold into one strip.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries

  defp open_display_options(lv),
    do: lv |> element("#calendar-display-options > button") |> render_click()

  # The ids inside one placement's display options, without its prefix, so
  # the toolbar's and the sheet's can be compared row for row.
  defp control_suffixes(lv, prefix) do
    lv
    |> element("##{prefix}-display-rows")
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.find("[id]")
    |> Enum.flat_map(&Floki.attribute(&1, "id"))
    |> Enum.map(&String.replace_prefix(&1, prefix <> "-", ""))
  end

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

  test "the toolbar and the Calendars sheet offer the same display options", %{conn: conn} do
    %{conn: conn} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    open_display_options(lv)
    toolbar = control_suffixes(lv, "calendar")

    lv |> element("#calendar-phone-calendars") |> render_click()
    sheet = control_suffixes(lv, "calendar-sheet")

    assert toolbar == sheet

    assert Enum.all?(
             ~w(density-comfortable density-compact fold-night back-to-old),
             &(&1 in toolbar)
           )
  end

  test "the toolbar's display options scroll within the window", %{conn: conn} do
    %{conn: conn} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    open_display_options(lv)

    assert has_element?(lv, "#calendar-display-options-panel.overflow-y-auto.w-80")
  end
end
