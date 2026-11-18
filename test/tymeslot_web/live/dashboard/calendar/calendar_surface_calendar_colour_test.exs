defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceCalendarColourTest do
  @moduledoc """
  Giving one calendar its own colour from the rail or the Calendars sheet:
  its swatch button opens the palette under it, a swatch stores the colour
  and repaints the calendar's events and its checkbox at once, "Default
  colour" gives it the account's colour again, and a calendar on someone
  else's account is refused.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.Factory
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Integrations.Calendar.Appearance

  setup %{conn: conn}, do: owner(conn)

  defp pushed(lv, id) do
    assert_push_event(lv, "calendar:events", %{reset: true, events: events})
    Enum.find(events, &(&1.id == id))
  end

  defp open_palette(lv, scope, _integration),
    do: lv |> element("#{scope} [data-calendar-colour='work']") |> render_click()

  defp palette(integration), do: "#calendar-calendar-#{integration.id}-work-colour-palette"

  test "a swatch in the rail colours the calendar and repaints its events", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    review = event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    refute has_element?(lv, palette(integration))
    open_palette(lv, "#calendar-rail", integration)

    assert has_element?(lv, "#calendar-rail [data-calendar-colour='work'][aria-expanded='true']")

    assert has_element?(
             lv,
             "#{palette(integration)} button[phx-value-colour='default'][aria-pressed='true']"
           )

    lv |> element("#{palette(integration)} button[phx-value-colour='grape']") |> render_click()

    assert %{colour: "calendar-grape"} = pushed(lv, "event-#{review.id}")

    assert Appearance.colour_keys(Appearance.list_for_user(user.id)) ==
             %{{integration.id, "work"} => "grape"}

    assert has_element?(
             lv,
             "#calendar-rail [data-calendar-id='work'] .cal-check[style*='calendar-grape']"
           )

    assert has_element?(
             lv,
             "#{palette(integration)} button[phx-value-colour='grape'][aria-pressed='true']"
           )
  end

  test "Default gives the calendar its account's colour again", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    {:ok, _appearance} = Appearance.set_colour(user.id, integration.id, "work", "grape")
    review = event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    open_palette(lv, "#calendar-rail", integration)
    lv |> element("#{palette(integration)} button[phx-value-colour='default']") |> render_click()

    refute pushed(lv, "event-#{review.id}").colour == "calendar-grape"
    assert Appearance.colour_keys(Appearance.list_for_user(user.id)) == %{}
  end

  test "the Calendars sheet offers the same palette", %{conn: conn, integration: integration} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:toggle_menu", %{"menu" => "calendars"})

    open_palette(lv, "#calendar-calendars-sheet", integration)

    assert has_element?(
             lv,
             "#calendar-sheet-calendar-#{integration.id}-work-colour-palette [role='group']"
           )
  end

  test "a calendar on someone else's account is refused", %{conn: conn} do
    other = insert(:calendar_integration, is_active: true)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:set_calendar_colour", %{
      "integration-id" => to_string(other.id),
      "calendar-id" => "work",
      "colour" => "grape"
    })

    assert render(lv) =~ "save that colour. Please try again."
    assert Appearance.colour_keys(Appearance.list_for_user(other.user_id)) == %{}
  end
end
