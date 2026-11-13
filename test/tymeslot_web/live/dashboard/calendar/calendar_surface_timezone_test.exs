defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceTimezoneTest do
  @moduledoc """
  The organiser's time zone on the calendar: the rail's foot on a
  desktop and the Calendars sheet on a phone name the zone every time is
  shown in, and lead to where it is set.
  The toolbar, already wrapping at 1280px with the sidebar, gives it no
  room.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers

  alias Ecto.Changeset
  alias Tymeslot.Profiles
  alias Tymeslot.Repo

  defp zone(lv, id) do
    lv
    |> element("##{id} [data-testid='timezone-display']")
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.text()
    |> String.trim()
  end

  test "the rail names the organiser's zone and leads to where it is set", %{conn: conn} do
    %{conn: conn} = owner(conn, timezone: "Europe/Kyiv")
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert zone(lv, "calendar-rail-timezone") == "Kyiv, Ukraine"

    assert has_element?(
             lv,
             ~s|#calendar-rail-timezone[aria-label="Times shown in Kyiv, Ukraine"]|
           )

    assert has_element?(
             lv,
             "#calendar-rail-timezone + [role='tooltip']",
             "Times shown in Kyiv, Ukraine"
           )

    lv |> element("#calendar-rail-timezone") |> render_click()
    assert_patch(lv, ~p"/dashboard/settings")
  end

  test "the rail keeps the zone in view as it scrolls, and the span leaves the tooltip to the link",
       %{conn: conn} do
    %{conn: conn} = owner(conn, timezone: "Europe/Kyiv")
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(
             lv,
             "#calendar-rail-timezone[class~='sticky'][class~='bottom-0'][class~='mt-auto']"
           )

    refute has_element?(lv, "#calendar-rail-timezone [data-testid='timezone-display'][title]")
  end

  test "a profile with no zone shows the host default the calendar is read in", %{conn: conn} do
    %{conn: conn, user: user} = owner(conn)
    user.id |> Profiles.get_profile() |> Changeset.change(timezone: nil) |> Repo.update!()

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert zone(lv, "calendar-rail-timezone") == "Tallinn, Estonia"
  end

  test "the toolbar and the phone header spend no width on it", %{conn: conn} do
    %{conn: conn} = owner(conn, timezone: "Europe/Kyiv")
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    refute has_element?(lv, "#calendar-toolbar [data-testid='timezone-display']")
    refute has_element?(lv, "#calendar-phone-header [data-testid='timezone-display']")
  end

  test "on a phone the Calendars sheet names it beside the display options", %{conn: conn} do
    %{conn: conn} = owner(conn, timezone: "Europe/Kyiv")

    {:ok, lv, _html} =
      live(put_connect_params(conn, %{"viewport" => "phone"}), ~p"/dashboard/calendar")

    lv |> element("#calendar-phone-calendars") |> render_click()

    assert zone(lv, "calendar-sheet-timezone") == "Kyiv, Ukraine"
    assert has_element?(lv, "#calendar-sheet-display #calendar-sheet-timezone[class~='min-h-11']")

    lv |> element("#calendar-sheet-timezone") |> render_click()
    assert_patch(lv, ~p"/dashboard/settings")
  end
end
