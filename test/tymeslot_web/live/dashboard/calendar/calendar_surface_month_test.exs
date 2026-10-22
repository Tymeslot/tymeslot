defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceMonthTest do
  @moduledoc """
  The month view on the server: its URL, title and steps, the window the
  hook draws it from, and the bookable layer it leaves unloaded.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Mox
  import TymeslotWeb.BookableLayerHelpers
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.CalendarMock
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries

  setup %{conn: conn}, do: owner(conn)

  test "a month URL opens on that month, titled with it, stepping by a month", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=month&date=2026-10-14")

    assert lv |> element("#calendar-period-title") |> render() =~ "October 2026"
    assert has_element?(lv, "#calendar-prev[aria-label='Previous month']")
    assert has_element?(lv, "#calendar-next[aria-label='Next month']")
  end

  test "next from 31 January lands on the last day of February", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=month&date=2026-01-31")

    lv |> element("#calendar-next") |> render_click()

    assert_patch(lv, "/dashboard/calendar?view=month&date=2026-02-28")
  end

  test "the hook's first request gets the month's six weeks with a month's grid either side",
       %{conn: conn, integration: integration} do
    event(integration, "work", "Early September", ~U[2026-09-01 09:00:00Z])
    event(integration, "work", "Too far", ~U[2026-12-10 09:00:00Z])

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=month&date=2026-10-14")
    lv |> element("#calendar-canvas") |> render_hook("calendar:ready", %{})

    assert_reply(lv, %{
      view: "month",
      date: "2026-10-14",
      range: %{from: "2026-08-31", to: "2026-12-07"},
      events: events
    })

    titles = Enum.map(events, & &1.title)
    assert "Early September" in titles
    refute "Too far" in titles
  end

  describe "with a meeting type" do
    setup %{user: user} do
      open_days(user)
      %{intro: meeting_type(user)}
    end

    test "month view computes no bookable times, and the week brings them back", %{conn: conn} do
      test_pid = self()

      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to ->
        send(test_pid, :fetched)
        {:ok, []}
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=month&date=2026-10-14")
      render_async(lv)

      refute_push_event(lv, "calendar:bookable", _layer)
      refute_received :fetched

      lv |> element("#calendar-view-week") |> render_click()

      assert %{on: true} = await_bookable(lv, &on_day?(&1, "2026-10-15"))
    end

    test "a week load still running when the month opens is dropped", %{conn: conn} do
      test_pid = self()

      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to ->
        send(test_pid, {:held, self()})

        receive do
          :release -> {:ok, []}
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=week&date=2026-10-14")
      assert_receive {:held, fetcher}, 2_000

      render_patch(lv, ~p"/dashboard/calendar?view=month&date=2026-10-14")

      # The fetch runs in the load's own task, which still computes the
      # windows once released: wait for that task to end, then render so
      # the LiveView has taken its answer, rather than racing the
      # computation against `render_async/1`'s default timeout.
      ref = Process.monitor(fetcher)
      send(fetcher, :release)
      assert_receive {:DOWN, ^ref, :process, ^fetcher, _reason}, 5_000
      render(lv)

      refute_push_event(lv, "calendar:bookable", _layer)
    end
  end

  describe "the toolbar, the stored default and the client copy" do
    test "the view switch offers Month and Agenda after the time views", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("#calendar-toolbar") |> render()

      positions =
        for view <- ~w(day three_day week month agenda),
            do: html |> :binary.match(~s(id="calendar-view-#{view}")) |> elem(0)

      assert positions == Enum.sort(positions)
      assert lv |> element("#calendar-view-month") |> render() =~ "Month"
      assert lv |> element("#calendar-view-agenda") |> render() =~ "Agenda"
    end

    # With five views the toolbar needs about 920px; at 768px, or 1024px
    # beside the dashboard sidebar, Month and Agenda ran off the edge.
    test "the toolbar wraps the views to a second row rather than cutting them off", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      assert has_element?(lv, "#calendar-toolbar[class~='flex-wrap'][class~='min-h-11']")
      refute has_element?(lv, "#calendar-toolbar[class~='h-11']")

      assert has_element?(
               lv,
               "#calendar-toolbar #calendar-toolbar-end[class~='ml-auto'] [role='group'] #calendar-view-agenda"
             )
    end

    test "Month patches the URL and pushes six weeks with a month's grid either side", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv |> element("#calendar-view-month") |> render_click()

      assert_patch(lv, "/dashboard/calendar?view=month&date=2026-10-14")

      assert_push_event(lv, "calendar:events", %{
        view: "month",
        reset: false,
        range: %{from: "2026-08-31", to: "2026-12-07"}
      })

      assert has_element?(lv, "#calendar-view-month[aria-pressed='true']")
    end

    test "Agenda patches the URL and pushes four weeks either side of its first", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv |> element("#calendar-view-agenda") |> render_click()

      assert_patch(lv, "/dashboard/calendar?view=agenda&date=2026-10-14")

      assert_push_event(lv, "calendar:events", %{
        view: "agenda",
        range: %{from: "2026-09-16", to: "2026-12-09"}
      })

      assert lv |> element("#calendar-period-title") |> render() =~ "From Wed 14 Oct"
    end

    test "a stored default of month or agenda opens that view", %{conn: conn, user: user} do
      {:ok, _prefs} = CalendarPreferencesQueries.upsert(user.id, %{default_view: "month"})
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      assert has_element?(lv, "#calendar-view-month[aria-pressed='true']")

      {:ok, _prefs} = CalendarPreferencesQueries.upsert(user.id, %{default_view: "agenda"})
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      assert has_element?(lv, "#calendar-view-agenda[aria-pressed='true']")
    end

    test "the canvas carries the month and agenda copy", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      assert has_element?(lv, "#calendar-canvas[data-strings*='agenda_later']")
      assert has_element?(lv, "#calendar-canvas[data-strings*='Nothing planned in these weeks.']")
    end
  end
end
