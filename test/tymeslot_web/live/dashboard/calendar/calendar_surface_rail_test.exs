defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceRailTest do
  @moduledoc """
  The new calendar's rail: calendars grouped by account with colour
  checkboxes and a lock on calendars Tymeslot cannot write to, and the rule
  that filters never hide silently: with the rail collapsed, hidden calendars
  show as a removable chip in the toolbar.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.Factory
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Integrations.Calendar.Appearance
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries

  setup %{conn: conn}, do: owner(conn)

  defp pushed_titles(lv) do
    assert_push_event(lv, "calendar:events", %{reset: true, events: events})
    Enum.map(events, & &1.title)
  end

  test "lists each account's calendars, ticked", %{conn: conn, integration: integration} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(lv, "#calendar-account-#{integration.id}", "Work account")
    assert has_element?(lv, "#calendar-rail [data-calendar-id='work'][aria-checked='true']")
    assert has_element?(lv, "#calendar-rail [data-calendar-id='family'][aria-checked='true']")
  end

  test "unticking a calendar hides its events, unticks it and remembers", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
    event(integration, "family", "School run", ~U[2026-10-14 07:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv |> element("#calendar-rail [data-calendar-id='family']") |> render_click()

    titles = pushed_titles(lv)
    assert "Design review" in titles
    refute "School run" in titles
    assert has_element?(lv, "#calendar-rail [data-calendar-id='family'][aria-checked='false']")
    assert {integration.id, "family"} in Appearance.hidden_keys(Appearance.list_for_user(user.id))
  end

  test "unticking an account hides every calendar in it", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv |> element("#calendar-rail [data-account-id='#{integration.id}']") |> render_click()

    assert pushed_titles(lv) == []

    assert CalendarPreferencesQueries.get_or_create(user.id).hidden_integration_ids == [
             integration.id
           ]
  end

  test "with the rail collapsed, hidden calendars show as a chip that brings them back",
       %{conn: conn, integration: integration} do
    event(integration, "family", "School run", ~U[2026-10-14 07:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv |> element("#calendar-rail [data-calendar-id='family']") |> render_click()
    _hidden = pushed_titles(lv)
    lv |> element("#calendar-rail-toggle") |> render_click()

    refute has_element?(lv, "#calendar-rail")
    assert has_element?(lv, "#calendar-filter-chip", "1 calendar hidden")

    lv |> element("#calendar-show-all") |> render_click()

    assert "School run" in pushed_titles(lv)
    refute has_element?(lv, "#calendar-filter-chip")
  end

  test "a calendar Tymeslot cannot write to carries a lock", %{conn: conn, user: user} do
    feed =
      insert(:calendar_integration,
        user: user,
        name: "Holidays",
        provider: "ics_url",
        is_active: true,
        calendar_list: [%{"id" => "feed", "name" => "Public holidays", "selected" => true}]
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(lv, "#calendar-account-#{feed.id} [title='Read only']")
  end

  test "an account id that is not the organiser's changes nothing", %{conn: conn, user: user} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:toggle_account", %{"integration-id" => "999999999"})

    assert CalendarPreferencesQueries.get_or_create(user.id).hidden_integration_ids == []
  end
end
