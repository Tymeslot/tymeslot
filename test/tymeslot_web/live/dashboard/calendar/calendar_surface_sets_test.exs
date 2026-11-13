defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceSetsTest do
  @moduledoc """
  Calendar sets on the calendar: saving what shows as a set, applying
  one by its digit or its rail row, leaving it with 0, the chip and the
  phone's Calendars button naming it, the rail's ticks editing it, renaming
  and deleting, and the organiser's own hidden choices surviving all of it.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.Factory
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.CalendarGrid.CalendarSets
  alias Tymeslot.Integrations.Calendar.Appearance
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries

  setup %{conn: conn} do
    %{integration: integration} = context = owner(conn)
    event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
    event(integration, "family", "School run", ~U[2026-10-14 07:00:00Z])
    context
  end

  defp family_set(user, integration),
    do:
      CalendarSets.create(user.id, "Family", [
        %{integration_id: integration.id, calendar_id: "family"}
      ])

  defp apply_set(lv, position),
    do:
      lv
      |> element("#calendar-canvas")
      |> render_hook("calendar:apply_set", %{"position" => position})

  defp pushed_titles(lv) do
    assert_push_event(lv, "calendar:events", %{reset: true, events: events})
    events |> Enum.map(& &1.title) |> Enum.sort()
  end

  defp active_id(user),
    do: CalendarPreferencesQueries.get_or_create(user.id).active_calendar_set_id

  defp manual_keys(user), do: user.id |> Appearance.list_for_user() |> Appearance.hidden_keys()

  test "New set saves the calendars shown and makes it the active set", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    {:ok, _appearance} = Appearance.set_hidden(user.id, integration.id, "family", true)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv |> element("#calendar-rail-new-set") |> render_click()
    lv |> form("#calendar-rail-set-form", %{"name" => "  Work  "}) |> render_submit()

    assert [%{name: "Work", position: 1, members: [member]} = set] = CalendarSets.list(user.id)
    assert {member.integration_id, member.calendar_id} == {integration.id, "work"}
    assert active_id(user) == set.id
    assert has_element?(lv, "#calendar-rail-set-1[aria-pressed='true']", "Work")
    refute has_element?(lv, "#calendar-rail-set-form")

    assert_push_event(lv, "calendar:focus", %{
      ids: ["calendar-rail-set-1", "calendar-sheet-set-1"]
    })

    assert_push_event(lv, "calendar:events", %{
      settings: %{sets: [%{position: 1, name: "Work"}], active_set: 1}
    })
  end

  test "a set's digit shows only its calendars, and 0 gives back the organiser's own", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    {:ok, _set} = family_set(user, integration)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    apply_set(lv, "1")

    assert pushed_titles(lv) == ["School run"]
    assert has_element?(lv, "#calendar-filter-chip", "Family set · 1 calendar hidden")
    assert has_element?(lv, "#calendar-show-all[aria-label='Leave the Family set']")
    assert has_element?(lv, "#calendar-rail-set-1[aria-pressed='true']")

    apply_set(lv, 0)

    assert pushed_titles(lv) == ["Design review", "School run"]
    refute has_element?(lv, "#calendar-filter-chip")
    assert has_element?(lv, "#calendar-rail-set-0[aria-pressed='true']")
    assert active_id(user) == nil
  end

  test "a set never rewrites the organiser's own hidden calendars", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    {:ok, _appearance} = Appearance.set_hidden(user.id, integration.id, "family", true)

    {:ok, _set} =
      CalendarSets.create(user.id, "Everything", [
        %{integration_id: integration.id, calendar_id: nil}
      ])

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    apply_set(lv, 1)
    assert pushed_titles(lv) == ["Design review", "School run"]
    assert has_element?(lv, "#calendar-filter-chip", "Everything set")

    apply_set(lv, 0)
    assert pushed_titles(lv) == ["Design review"]
    assert manual_keys(user) == MapSet.new([{integration.id, "family"}])
  end

  test "an active set is applied on the next visit", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    {:ok, _set} = family_set(user, integration)
    {:ok, _active} = CalendarSets.activate(user.id, 1)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv |> element("#calendar-canvas") |> render_hook("calendar:ready", %{})

    assert_reply(lv, %{events: events, settings: %{active_set: 1, sets: [%{name: "Family"}]}})
    assert Enum.map(events, & &1.title) == ["School run"]
    assert has_element?(lv, "#calendar-rail [data-calendar-id='work'][aria-checked='false']")
  end

  test "while a set is active, ticking a calendar edits the set, not the organiser's choice", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    {:ok, _set} = family_set(user, integration)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    apply_set(lv, 1)
    _family = pushed_titles(lv)

    lv |> element("#calendar-rail [data-calendar-id='work']") |> render_click()

    assert pushed_titles(lv) == ["Design review", "School run"]
    assert [%{members: members}] = CalendarSets.list(user.id)
    assert Enum.sort(Enum.map(members, & &1.calendar_id)) == ["family", "work"]
    assert manual_keys(user) == MapSet.new()
    assert has_element?(lv, "#calendar-filter-chip", "Family set")
  end

  test "the chip's × leaves the set", %{conn: conn, user: user, integration: integration} do
    {:ok, _set} = family_set(user, integration)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    apply_set(lv, 1)
    _family = pushed_titles(lv)

    lv |> element("#calendar-show-all") |> render_click()

    assert pushed_titles(lv) == ["Design review", "School run"]
    assert active_id(user) == nil
    assert [%{name: "Family"}] = CalendarSets.list(user.id)
  end

  test "a set is renamed and deleted from its pencil", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    {:ok, _set} = family_set(user, integration)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    apply_set(lv, 1)

    lv |> element("#calendar-rail-set-1-edit") |> render_click()
    assert has_element?(lv, "#calendar-rail-set-name[value='Family']")
    lv |> form("#calendar-rail-set-form", %{"name" => "Home"}) |> render_submit()

    assert [%{name: "Home"}] = CalendarSets.list(user.id)
    assert has_element?(lv, "#calendar-filter-chip", "Home set")

    lv |> element("#calendar-rail-set-1-edit") |> render_click()
    lv |> element("#calendar-rail-set-1-delete") |> render_click()

    assert CalendarSets.list(user.id) == []
    assert active_id(user) == nil
    refute has_element?(lv, "#calendar-filter-chip")
    refute has_element?(lv, "#calendar-rail-set-1")
  end

  test "a tenth set is refused and says why", %{conn: conn, user: user} do
    for n <- 1..9, do: {:ok, _set} = CalendarSets.create(user.id, "Set #{n}", [])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    refute has_element?(lv, "#calendar-rail-new-set")

    canvas = element(lv, "#calendar-canvas")
    render_hook(canvas, "calendar:edit_set", %{"new" => "true"})
    render_hook(canvas, "calendar:save_set", %{"name" => "Tenth"})

    assert length(CalendarSets.list(user.id)) == 9
    assert render(lv) =~ "You can keep up to nine calendar sets."
  end

  test "a blank name saves nothing", %{conn: conn, user: user} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv |> element("#calendar-rail-new-set") |> render_click()
    lv |> form("#calendar-rail-set-form", %{"name" => "   "}) |> render_submit()

    assert CalendarSets.list(user.id) == []
    assert has_element?(lv, "#calendar-rail-set-form")
  end

  test "a digit with no set, a forged position or another organiser's set changes nothing", %{
    conn: conn,
    user: user
  } do
    {:ok, _theirs} = CalendarSets.create(insert(:user).id, "Theirs", [])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    apply_set(lv, 1)
    apply_set(lv, "12")
    apply_set(lv, "one")

    assert active_id(user) == nil
    refute has_element?(lv, "#calendar-filter-chip")
    refute_push_event(lv, "calendar:events", %{reset: true})
  end

  test "the phone's Calendars button and the Calendars sheet name the active set", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    {:ok, _set} = family_set(user, integration)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    apply_set(lv, 1)

    assert has_element?(lv, "#calendar-phone-calendars", "Family")

    lv |> element("#calendar-phone-calendars") |> render_click()

    assert has_element?(lv, "#calendar-sheet-set-1[aria-pressed='true']", "Family")
    refute has_element?(lv, "#calendar-sheet-hidden")
  end

  test "ticking a calendar of an account outside the set adds only that calendar", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    other =
      insert(:calendar_integration,
        user: user,
        name: "Other account",
        provider: "google",
        is_active: true,
        calendar_list: [
          %{"id" => "extra", "name" => "Extra", "selected" => true},
          %{"id" => "misc", "name" => "Misc", "selected" => true}
        ]
      )

    event(other, "extra", "Extra thing", ~U[2026-10-14 11:00:00Z])
    event(other, "misc", "Misc thing", ~U[2026-10-14 12:00:00Z])
    {:ok, _set} = family_set(user, integration)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    apply_set(lv, 1)
    assert pushed_titles(lv) == ["School run"]
    assert has_element?(lv, "#calendar-rail [data-calendar-id='extra'][aria-checked='false']")

    lv |> element("#calendar-rail [data-calendar-id='extra']") |> render_click()

    assert pushed_titles(lv) == ["Extra thing", "School run"]
    assert [%{members: members}] = CalendarSets.list(user.id)

    assert members |> Enum.map(&{&1.integration_id, &1.calendar_id}) |> Enum.sort() ==
             Enum.sort([{integration.id, "family"}, {other.id, "extra"}])
  end
end
