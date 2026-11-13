defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfacePhoneTest do
  @moduledoc """
  The calendar on a phone: which view it opens (a week shows as three
  days, without touching the URL or the stored default), how the server
  learns the width (the socket's connect params, the user agent on the
  first render, then the hook), and the shell that keeps the first paint
  right.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers

  @iphone "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
  @desktop "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

  defp phone(conn), do: put_connect_params(conn, %{"viewport" => "phone"})

  defp ready(lv, params),
    do: lv |> element("#calendar-canvas") |> render_hook("calendar:ready", params)

  defp report(lv, params),
    do: lv |> element("#calendar-canvas") |> render_hook("calendar:viewport", params)

  defp skeleton_columns(html), do: length(Regex.scan(~r/class="cal-skeleton-col"/, html))

  describe "which view a phone opens" do
    test "a stored week opens as three days", %{conn: conn} do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(phone(conn), ~p"/dashboard/calendar")

      ready(lv, %{"phone" => true})

      assert_reply(lv, %{
        view: "three_day",
        date: "2026-10-14",
        range: %{from: "2026-10-11", to: "2026-10-20"}
      })
    end

    test "a stored day stays a day", %{conn: conn} do
      %{conn: conn} = owner(conn, preferences: [default_view: "day"])
      {:ok, lv, _html} = live(phone(conn), ~p"/dashboard/calendar")

      ready(lv, %{"phone" => true})

      assert_reply(lv, %{view: "day"})
    end

    test "a linked week shows three days and the URL is left alone", %{conn: conn} do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(phone(conn), ~p"/dashboard/calendar?view=week&date=2026-10-14")

      ready(lv, %{"phone" => true})

      assert_reply(lv, %{view: "three_day", date: "2026-10-14"})
      refute_patched(lv)
    end

    test "a month is shown as a month", %{conn: conn} do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(phone(conn), ~p"/dashboard/calendar?view=month&date=2026-10-14")

      ready(lv, %{"phone" => true})

      assert_reply(lv, %{view: "month"})
    end
  end

  describe "how the server learns the width" do
    test "the first render reads a phone from the user agent", %{conn: conn} do
      %{conn: conn} = owner(conn)

      html =
        conn
        |> put_req_header("user-agent", @iphone)
        |> get(~p"/dashboard/calendar")
        |> html_response(200)

      assert html =~ ~s(data-view="three_day")
      assert skeleton_columns(html) == 3
    end

    test "a desktop user agent gets the week", %{conn: conn} do
      %{conn: conn} = owner(conn)

      html =
        conn
        |> put_req_header("user-agent", @desktop)
        |> get(~p"/dashboard/calendar")
        |> html_response(200)

      assert html =~ ~s(data-view="week")
      assert skeleton_columns(html) == 7
    end

    test "the hook's first request corrects a wrong guess", %{conn: conn} do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      ready(lv, %{"phone" => true})

      assert_reply(lv, %{view: "three_day", range: %{from: "2026-10-11", to: "2026-10-20"}})
      refute_push_event(lv, "calendar:events", %{})
    end

    test "a report of a wide screen puts the week back, and a phone again takes it away",
         %{conn: conn} do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(phone(conn), ~p"/dashboard/calendar")

      report(lv, %{"phone" => false})

      assert_push_event(lv, "calendar:events", %{
        view: "week",
        range: %{from: "2026-10-05", to: "2026-10-26"}
      })

      report(lv, %{"phone" => true})

      assert_push_event(lv, "calendar:events", %{view: "three_day"})
    end

    test "a rotation that changes the view keeps an open sheet", %{conn: conn} do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(phone(conn), ~p"/dashboard/calendar")
      ready(lv, %{"phone" => true})

      lv |> element("#calendar-phone-calendars") |> render_click()
      assert has_element?(lv, "#calendar-calendars-sheet")

      report(lv, %{"phone" => false})

      assert has_element?(lv, "#calendar-calendars-sheet")
      assert has_element?(lv, "#calendar-view-week[aria-pressed='true']")
      assert_push_event(lv, "calendar:events", %{view: "week"})
    end

    test "the width the hook reported holds when the page moves on", %{conn: conn} do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(phone(conn), ~p"/dashboard/calendar")
      report(lv, %{"phone" => false})

      lv |> element("#calendar-next") |> render_click()

      assert_patch(lv, ~p"/dashboard/calendar?view=week&date=2026-10-21")
      assert has_element?(lv, "#calendar-view-week[aria-pressed='true']")
    end

    test "a report that is not a yes or a no changes nothing", %{conn: conn} do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(phone(conn), ~p"/dashboard/calendar")

      report(lv, %{"phone" => "no"})

      refute_push_event(lv, "calendar:events", %{})
    end
  end

  describe "the shell" do
    test "the dashboard fills the dynamic viewport and clears the notch", %{conn: conn} do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      assert has_element?(lv, "#dashboard-root[class~='h-dvh']")
      refute has_element?(lv, "#dashboard-root[class~='h-screen']")
      assert has_element?(lv, "#dashboard-root[class~='pl-[env(safe-area-inset-left)]']")
      assert has_element?(lv, "#dashboard-root[class~='pr-[env(safe-area-inset-right)]']")
    end

    test "dashboard pages run under the notch and let the keyboard resize them", %{conn: conn} do
      %{conn: conn} = owner(conn)
      html = conn |> get(~p"/dashboard/calendar") |> html_response(200)

      assert html =~
               ~s(content="width=device-width, initial-scale=1, viewport-fit=cover, interactive-widget=resizes-content")
    end

    test "every page of the dashboard session, the account page too, runs under the notch",
         %{conn: conn} do
      %{conn: conn} = owner(conn)
      html = conn |> get(~p"/dashboard/account") |> html_response(200)

      assert html =~ "viewport-fit=cover"
    end

    test "pages outside the dashboard keep the plain viewport" do
      html = build_conn() |> get(~p"/auth/login") |> html_response(200)

      assert html =~ ~s(content="width=device-width, initial-scale=1")
      refute html =~ "viewport-fit"
    end

    test "the rail, the canvas and the panel share one row the phone CSS can lift", %{conn: conn} do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      assert has_element?(lv, "#calendar-surface .cal-row #calendar-canvas")
      assert has_element?(lv, "#calendar-surface .cal-row #calendar-rail")
    end

    test "a day's first paint is one skeleton column", %{conn: conn} do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(phone(conn), ~p"/dashboard/calendar?view=day&date=2026-10-14")

      assert has_element?(lv, "#calendar-canvas .cal-skeleton-col")
      refute has_element?(lv, "#calendar-canvas .cal-skeleton-col:nth-child(2)")
    end
  end

  describe "the phone header" do
    test "the Calendars button says when calendars are hidden", %{conn: conn} do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(phone(conn), ~p"/dashboard/calendar")

      assert has_element?(lv, "#calendar-phone-calendars[class~='h-11']", "Calendars")
      refute has_element?(lv, "#calendar-phone-calendars", "hidden")
      refute has_element?(lv, "#calendar-phone-calendars[class~='bg-amber-50']")

      lv |> element("#calendar-rail [data-calendar-id='family']") |> render_click()

      assert has_element?(lv, "#calendar-phone-calendars[class~='bg-amber-50']", "1 hidden")
    end

    # At 360px the icon beside "1 hidden" left the period a few letters wide.
    test "the hidden count takes the icon's place until none are hidden", %{
      conn: conn
    } do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(phone(conn), ~p"/dashboard/calendar")

      assert has_element?(lv, "#calendar-phone-calendars svg")

      lv |> element("#calendar-rail [data-calendar-id='family']") |> render_click()

      refute has_element?(lv, "#calendar-phone-calendars svg")
      assert has_element?(lv, "#calendar-phone-calendars .sr-only", "Calendars")

      lv |> element("#calendar-rail [data-calendar-id='family']") |> render_click()

      assert has_element?(lv, "#calendar-phone-calendars svg")
    end

    test "the period stays on one line, in full for screen readers", %{conn: conn} do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(phone(conn), ~p"/dashboard/calendar")

      assert has_element?(lv, "#calendar-phone-title span[class~='truncate']", "14 – 16 Oct")
      refute has_element?(lv, "#calendar-phone-title span[class~='line-clamp-2']")
      assert has_element?(lv, "#calendar-phone-title[aria-label='Choose a date, 14 to 16 Oct']")
    end

    test "Today shows today's date and is named Today", %{conn: conn} do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(phone(conn), ~p"/dashboard/calendar")

      assert has_element?(lv, "#calendar-phone-today[aria-label='Today']")
      assert has_element?(lv, "#calendar-phone-today + [role='tooltip']", "Today")
      assert has_element?(lv, "#calendar-phone-today span[aria-hidden='true']", "14")
    end

    test "shows the period between 44px previous and next buttons", %{conn: conn} do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(phone(conn), ~p"/dashboard/calendar")

      assert has_element?(lv, "#calendar-phone-title", "14 – 16 Oct")

      for id <- ~w(calendar-phone-prev calendar-phone-next calendar-phone-today) do
        assert has_element?(lv, "##{id}[class~='h-11'][class~='min-w-11']")
      end

      assert has_element?(lv, "#calendar-phone-prev[aria-label='Previous three days']")
      assert has_element?(lv, "#calendar-phone-next[aria-label='Next three days']")
    end

    test "next steps by the period shown", %{conn: conn} do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(phone(conn), ~p"/dashboard/calendar")

      lv |> element("#calendar-phone-next") |> render_click()

      assert_patch(lv, ~p"/dashboard/calendar?view=three_day&date=2026-10-17")
      assert has_element?(lv, "#calendar-phone-title", "17 – 19 Oct")
    end

    test "Today goes back to today", %{conn: conn} do
      %{conn: conn} = owner(conn)

      {:ok, lv, _html} =
        live(phone(conn), ~p"/dashboard/calendar?view=three_day&date=2026-10-30")

      assert has_element?(lv, "#calendar-phone-title", "30 Oct – 1 Nov")

      lv |> element("#calendar-phone-today") |> render_click()

      assert_patch(lv, ~p"/dashboard/calendar?view=three_day&date=2026-10-14")
    end

    test "is shown on phones only, as the toolbar is hidden there", %{conn: conn} do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      assert has_element?(lv, "#calendar-phone-header[class~='sm:hidden']")
      assert has_element?(lv, "#calendar-toolbar[class~='max-sm:hidden']")
    end

    test "has a title for a week too, for a phone the server took for wide", %{conn: conn} do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      assert has_element?(lv, "#calendar-phone-title", "12 – 18 Oct")
    end
  end

  describe "the tabs and the + button" do
    test "a phone gets Agenda, Day, 3 days and Month, its view current", %{conn: conn} do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(phone(conn), ~p"/dashboard/calendar")

      tabs = lv |> element("#calendar-tabs") |> render()

      ids =
        ~r/id="calendar-tab-(\w+)"/ |> Regex.scan(tabs, capture: :all_but_first) |> List.flatten()

      assert ids == ~w(agenda day three_day month)
      assert has_element?(lv, "nav#calendar-tabs[aria-label='Views']")
      assert has_element?(lv, "#calendar-tab-three_day[aria-current='page']", "3 days")
      refute has_element?(lv, "#calendar-tab-day[aria-current]")
      assert has_element?(lv, "#calendar-tab-agenda", "Agenda")
      assert has_element?(lv, "#calendar-tab-month", "Month")
    end

    test "a tab switches the view where the organiser is", %{conn: conn} do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(phone(conn), ~p"/dashboard/calendar")

      lv |> element("#calendar-tab-month") |> render_click()

      assert_patch(lv, ~p"/dashboard/calendar?view=month&date=2026-10-14")
      assert has_element?(lv, "#calendar-tab-month[aria-current='page']")
    end

    test "while a week shows, the 3 days tab is current", %{conn: conn} do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      assert has_element?(lv, "#calendar-tab-three_day[aria-current='page']")
    end

    test "the tab bar is the surface's last child, in normal flow, at least 44px a tab",
         %{conn: conn} do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(phone(conn), ~p"/dashboard/calendar")

      assert has_element?(lv, "#calendar-surface > nav#calendar-tabs:last-child")
      assert has_element?(lv, "#calendar-tabs[class~='sm:hidden']")
      assert has_element?(lv, "#calendar-tab-day[class~='min-h-11']")
    end

    test "the + button opens quick create, as Create does", %{conn: conn} do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(phone(conn), ~p"/dashboard/calendar")

      assert has_element?(
               lv,
               "#calendar-fab[aria-label='New event'][aria-keyshortcuts='c'][phx-click*='calendar:quick-create']"
             )

      assert has_element?(lv, "#calendar-fab[class~='sm:hidden']")
    end
  end

  test "the toast region is placed by the calendar's stylesheet, not by utilities",
       %{conn: conn} do
    %{conn: conn} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(lv, "#calendar-toast-region[class~='cal-toast-region'][role='status']")
    refute has_element?(lv, "#calendar-toast-region[class~='z-40']")
    refute has_element?(lv, "#calendar-toast-region[class~='bottom-4']")
  end
end
