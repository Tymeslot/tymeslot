defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfacePhoneTest do
  @moduledoc """
  The new calendar on a phone: which view it opens (a week shows as three
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
end
