defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceTest do
  @moduledoc """
  The calendar's shell: the surface it renders, the one-row toolbar, the URL
  state, and the event payload the canvas hook draws from.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries

  setup %{conn: conn}, do: owner(conn)

  test "the calendar page renders the surface", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(lv, "#calendar-surface")
    assert has_element?(lv, "#calendar-canvas[phx-hook='CalendarCanvas'][phx-update='ignore']")
    refute has_element?(lv, "#calendar-grid")
  end

  test "first paint is a labelled skeleton until the hook has data", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(
             lv,
             "#calendar-canvas[aria-busy='true'] [role='status'][aria-label='Loading calendar']"
           )
  end

  test "opens on this week, titled with its month", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert lv |> element("#calendar-period-title") |> render() =~ "October 2026"
    assert has_element?(lv, "#calendar-view-week[aria-pressed='true']")
  end

  test "the hook's first request gets this week plus a week either side, in the organiser's wall clock",
       %{conn: conn, integration: integration} do
    event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
    event(integration, "work", "Last week's retro", ~U[2026-10-07 09:00:00Z])
    event(integration, "work", "Too far", ~U[2026-11-04 09:00:00Z])

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("#calendar-canvas") |> render_hook("calendar:ready", %{})

    assert_reply(lv, %{
      view: "week",
      date: "2026-10-14",
      range: %{from: "2026-10-05", to: "2026-10-26"},
      reset: true,
      events: events
    })

    titles = Enum.map(events, & &1.title)
    assert "Last week's retro" in titles
    refute "Too far" in titles

    assert %{start: "2026-10-14T10:00", end: "2026-10-14T11:00", kind: "event"} =
             Enum.find(events, &(&1.title == "Design review"))
  end

  test "the payload carries the display settings the grid needs", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("#calendar-canvas") |> render_hook("calendar:ready", %{})

    assert_reply(lv, %{
      settings: %{
        week_start: "monday",
        show_weekends: true,
        density: "comfortable",
        fold_night: true,
        time_format: "24h",
        working_hours: %{1 => [480, 1080], 6 => nil}
      }
    })
  end

  test "the settings carry the calendars a create can target and the one it starts on",
       %{conn: conn, integration: integration} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("#calendar-canvas") |> render_hook("calendar:ready", %{})

    work = "#{integration.id}:work"
    family = "#{integration.id}:family"

    assert_reply(lv, %{
      settings: %{
        calendars: [
          %{key: ^work, name: "Work", account: "Work account"},
          %{key: ^family, name: "Family", account: "Work account"}
        ],
        default_calendar: ^work
      }
    })
  end

  test "each event names its calendar", %{conn: conn, integration: integration} do
    event(integration, "family", "Swimming", ~U[2026-10-14 16:00:00Z])

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("#calendar-canvas") |> render_hook("calendar:ready", %{})

    assert_reply(lv, %{events: events})
    family = "#{integration.id}:family"

    assert %{calendar: ^family, recurring: false, guests: 0} =
             Enum.find(events, &(&1.title == "Swimming"))
  end

  test "a URL naming a view and date opens on that period", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=day&date=2026-10-20")

    assert has_element?(lv, "#calendar-view-day[aria-pressed='true']")
    assert lv |> element("#calendar-period-title") |> render() =~ "20 October 2026"
  end

  # The toolbar is a container: a narrow one shows the short date, a wide one the full.
  test "day view's title has a short form for a narrow toolbar, the full date in its tooltip",
       %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=day&date=2026-10-20")

    full = "#calendar-period-title[class~='@max-6xl:hidden']"
    short = "#calendar-period-title-short[class~='@6xl:hidden'][title='Tuesday, 20 October 2026']"
    assert has_element?(lv, full, "20 October 2026")
    assert has_element?(lv, short, "Tue 20 Oct")

    lv |> element("#calendar-view-week") |> render_click()

    refute has_element?(lv, "#calendar-period-title-short")
    refute has_element?(lv, "#calendar-period-title[class~='@max-6xl:hidden']")
  end

  test "day view loads its week with a week either side, so switching to that week needs no query",
       %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=day&date=2026-10-14")
    lv |> element("#calendar-canvas") |> render_hook("calendar:ready", %{})

    assert_reply(lv, %{view: "day", range: %{from: "2026-10-05", to: "2026-10-26"}})

    lv |> element("#calendar-view-week") |> render_click()

    assert_patch(lv, "/dashboard/calendar?view=week&date=2026-10-14")
    assert_push_event(lv, "calendar:period", %{view: "week", date: "2026-10-14"})
    refute_push_event(lv, "calendar:events", _payload)
  end

  test "a URL it cannot read falls back to this week instead of failing", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=fortnight&date=not-a-date")

    assert has_element?(lv, "#calendar-view-week[aria-pressed='true']")
    assert lv |> element("#calendar-period-title") |> render() =~ "October 2026"
  end

  test "next patches the URL to the following week and pushes its events",
       %{conn: conn, integration: integration} do
    event(integration, "work", "Next week's planning", ~U[2026-10-28 10:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv |> element("#calendar-next") |> render_click()

    assert_patch(lv, "/dashboard/calendar?view=week&date=2026-10-21")

    assert_push_event(lv, "calendar:events", %{
      date: "2026-10-21",
      range: %{from: "2026-10-12", to: "2026-11-02"},
      reset: false,
      events: events
    })

    assert Enum.any?(events, &(&1.title == "Next week's planning"))
  end

  test "previous and Today step back and return", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=three_day&date=2026-11-10")

    lv |> element("#calendar-prev") |> render_click()
    assert_patch(lv, "/dashboard/calendar?view=three_day&date=2026-11-07")

    lv |> element("#calendar-today") |> render_click()
    assert_patch(lv, "/dashboard/calendar?view=three_day&date=2026-10-14")
  end

  test "the view switch keeps the date and changes the view", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=week&date=2026-10-14")

    lv |> element("#calendar-view-three_day") |> render_click()

    assert_patch(lv, "/dashboard/calendar?view=three_day&date=2026-10-14")
    assert has_element?(lv, "#calendar-view-three_day[aria-pressed='true']")
  end

  test "the period title opens a date picker that jumps to the chosen day", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv |> element("#calendar-date-picker > button") |> render_click()

    lv
    |> element("#calendar-picker-month button[aria-label='Thursday, 29 October 2026']")
    |> render_click()

    assert_patch(lv, "/dashboard/calendar?view=week&date=2026-10-29")
  end

  test "the date picker pages through months", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv |> element("#calendar-date-picker > button") |> render_click()
    lv |> element("#calendar-picker-month button[aria-label='Next month']") |> render_click()

    assert lv |> element("#calendar-picker-month") |> render() =~ "November 2026"
  end

  test "a day header click in the canvas opens that day", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:goto", %{"view" => "day", "date" => "2026-10-15"})

    assert_patch(lv, "/dashboard/calendar?view=day&date=2026-10-15")
  end

  test "the date picker's trigger names the period it shows", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(
             lv,
             "#calendar-date-picker > button[aria-label='Choose a date, October 2026']"
           )

    refute has_element?(lv, "#calendar-toolbar[role='toolbar']")
  end

  test "the picker marks the visible range for screen readers, not by colour alone", %{
    conn: conn
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("#calendar-date-picker > button") |> render_click()

    assert has_element?(
             lv,
             "#calendar-picker-month button[aria-label='Friday, 16 October 2026'][aria-pressed='true']"
           )

    assert has_element?(
             lv,
             "#calendar-picker-month button[aria-label='Thursday, 22 October 2026'][aria-pressed='false']"
           )
  end

  test "picking the day already shown closes the date picker", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("#calendar-date-picker > button") |> render_click()
    assert has_element?(lv, "#calendar-date-picker-panel")

    lv
    |> element("#calendar-picker-month button[aria-label='Wednesday, 14 October 2026']")
    |> render_click()

    refute has_element?(lv, "#calendar-date-picker-panel")
  end

  test "picking another day of the visible week pushes no new events", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("#calendar-date-picker > button") |> render_click()

    lv
    |> element("#calendar-picker-month button[aria-label='Friday, 16 October 2026']")
    |> render_click()

    assert_patch(lv, "/dashboard/calendar?view=week&date=2026-10-16")
    refute_push_event(lv, "calendar:events", _payload)
    refute has_element?(lv, "#calendar-date-picker-panel")
  end

  # The hook holds a navigation as pending until the server confirms it, and
  # follows nothing else meanwhile; without this answer Back would stop working.
  test "a URL change that needs no new events still tells the hook the period", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("#calendar-date-picker > button") |> render_click()

    lv
    |> element("#calendar-picker-month button[aria-label='Friday, 16 October 2026']")
    |> render_click()

    assert_patch(lv, "/dashboard/calendar?view=week&date=2026-10-16")
    assert_push_event(lv, "calendar:period", %{view: "week", date: "2026-10-16"})
  end

  test "Today from another day of this week answers with the period", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=week&date=2026-10-16")

    lv |> element("#calendar-today") |> render_click()

    assert_patch(lv, "/dashboard/calendar?view=week&date=2026-10-14")
    assert_push_event(lv, "calendar:period", %{view: "week", date: "2026-10-14"})
    refute_push_event(lv, "calendar:events", _payload)
  end

  test "controls aiming at the period shown draw without adding a history entry", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/dashboard/calendar?view=week&date=2026-10-14")

    ops = fn selector ->
      html
      |> Floki.parse_document!()
      |> Floki.find(selector)
      |> Floki.attribute("phx-click")
      |> List.first()
      |> Jason.decode!()
      |> Enum.map(&hd/1)
    end

    assert ops.("#calendar-today") == ["dispatch"]
    assert ops.("#calendar-view-week") == ["dispatch"]

    # The shown day closes the picker it sits in instead of patching.
    assert ops.("#calendar-rail-month button[aria-label='Wednesday, 14 October 2026']") ==
             ["push", "dispatch"]

    # Still clickable, and every other target still patches.
    assert has_element?(lv, "#calendar-today")
    assert ops.("#calendar-view-day") == ["patch", "dispatch"]

    assert ops.("#calendar-rail-month button[aria-label='Thursday, 15 October 2026']") == [
             "patch",
             "dispatch"
           ]
  end

  test "the toolbar's Create opens quick create in the canvas, as C does, and the hint says so",
       %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(lv, "#calendar-create[aria-keyshortcuts='c']", "Create")
    # A narrow toolbar keeps only the icon; the name stays for screen readers and the tooltip.
    assert has_element?(
             lv,
             "#calendar-create[aria-describedby='calendar-create-tip'] span[class~='@max-5xl:sr-only']",
             "Create"
           )

    assert has_element?(lv, "#calendar-create-tip[role='tooltip']", "Create")

    ops =
      html
      |> Floki.parse_document!()
      |> Floki.find("#calendar-create")
      |> Floki.attribute("phx-click")
      |> List.first()
      |> Jason.decode!()

    assert [["dispatch", %{"event" => "calendar:quick-create", "to" => "#calendar-canvas"}]] =
             ops

    assert lv |> element("#calendar-keys-hint") |> render() =~
             "Press C to add an event at the next free time."
  end

  test "the keys hint names T, J and K", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(
             lv,
             "#calendar-shortcuts-hint",
             "Press T for today, J and K for the next and previous period"
           )
  end

  test "the hook's first request carries the power layer's settings at their defaults",
       %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("#calendar-canvas") |> render_hook("calendar:ready", %{})

    assert_reply(lv, %{
      settings: %{
        show_week_numbers: false,
        sets: [],
        active_set: 0,
        focus: false,
        desktop_reminders: false
      }
    })
  end

  test "the parent re-rendering pushes no events", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    send(lv.pid, :agenda_tick)
    _html = render(lv)

    refute_push_event(lv, "calendar:events", _payload)
  end

  test "a mini month shift in an unknown direction changes nothing and does not crash", %{
    conn: conn
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("#calendar-date-picker > button") |> render_click()

    for dir <- ["sideways", nil, 2, "1.5"] do
      lv |> element("#calendar-canvas") |> render_hook("calendar:mini_shift", %{"dir" => dir})
    end

    assert lv |> element("#calendar-picker-month") |> render() =~ "October 2026"
    assert has_element?(lv, "#calendar-surface")
  end

  test "an unknown density is ignored", %{conn: conn, user: user} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    for params <- [%{"option" => "cramped"}, %{"option" => 5}, %{}] do
      lv |> element("#calendar-canvas") |> render_hook("calendar:set_density", params)
    end

    refute_push_event(lv, "calendar:settings", _payload)
    assert CalendarPreferencesQueries.get_or_create(user.id).density == "comfortable"
  end
end
