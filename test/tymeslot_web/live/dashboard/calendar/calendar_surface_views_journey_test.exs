defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceViewsJourneyTest do
  @moduledoc """
  The organiser's journeys through the month and agenda views and the phone
  layout of the calendar: read a month, step to the next, open a day;
  read the agenda and scroll it four weeks at a time to its end, with hidden
  calendars staying hidden; open the calendar on a phone, where a week shows
  as 3 days without the URL or the stored default changing, and move with
  the tabs and the header; hide a calendar and pick a date from the phone's
  sheets.

  The hook's clicks are client side, so the test pushes the events the hook
  pushes (`calendar:ready`, `calendar:goto`, `calendar:viewport`,
  `calendar:agenda_more`) with the params the hook sends.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live
  @moduletag :integration

  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries

  @iphone "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
  @desktop "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

  defp titles(events), do: Enum.map(events, & &1.title)

  defp hook(lv, name, params), do: lv |> element("#calendar-canvas") |> render_hook(name, params)

  defp ready(lv, params \\ %{}) do
    hook(lv, "calendar:ready", params)
    assert_reply(lv, reply)
    reply
  end

  defp more(lv, through) do
    hook(lv, "calendar:agenda_more", %{"through" => through})
    assert_reply(lv, reply)
    reply
  end

  defp phone_conn(conn), do: put_connect_params(conn, %{"viewport" => "phone"})

  describe "month" do
    test "read a month, step to the next, open a day, and a stored month default opens it", %{
      conn: conn
    } do
      %{conn: conn, user: user, integration: integration} = owner(conn)
      event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
      event(integration, "family", "Half-term trip", ~U[2026-11-02 09:00:00Z])
      event(integration, "work", "Summer debrief", ~U[2026-08-20 09:00:00Z])

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=month&date=2026-10-14")

      # 1. The month loads with the months either side, and nothing older.
      assert %{
               view: "month",
               date: "2026-10-14",
               range: %{from: "2026-08-31", to: "2026-12-07"},
               events: events
             } = ready(lv)

      assert ["Design review", "Half-term trip"] -- titles(events) == []
      refute "Summer debrief" in titles(events)

      assert has_element?(lv, "#calendar-view-month[aria-pressed='true']")
      assert lv |> element("#calendar-period-title") |> render() =~ "October 2026"
      assert has_element?(lv, "#calendar-next[aria-label='Next month']")
      assert has_element?(lv, "#calendar-prev[aria-label='Previous month']")

      # 2. Next month: the URL follows and the new window arrives.
      lv |> element("#calendar-next") |> render_click()
      assert_patch(lv, "/dashboard/calendar?view=month&date=2026-11-14")

      assert_push_event(lv, "calendar:events", %{
        view: "month",
        date: "2026-11-14",
        range: %{from: "2026-09-28", to: "2027-01-11"}
      })

      # 3. A day clicked in the month opens Day view on that day (desktop).
      hook(lv, "calendar:goto", %{"view" => "day", "date" => "2026-11-02"})
      assert_patch(lv, "/dashboard/calendar?view=day&date=2026-11-02")

      assert_push_event(lv, "calendar:events", %{
        view: "day",
        date: "2026-11-02",
        range: %{from: "2026-10-26", to: "2026-11-16"},
        events: day_events
      })

      assert "Half-term trip" in titles(day_events)
      assert has_element?(lv, "#calendar-view-day[aria-pressed='true']")

      # 4. An organiser whose stored default is month opens in month.
      {:ok, _prefs} = CalendarPreferencesQueries.upsert(user.id, %{default_view: "month"})
      {:ok, reopened, _html} = live(conn, ~p"/dashboard/calendar")
      assert %{view: "month", date: "2026-10-14"} = ready(reopened)
    end
  end

  describe "switching view" do
    test "starts the next view at the week or month shown, today when it is in it", %{
      conn: conn
    } do
      %{conn: conn} = owner(conn)

      # Today is Wednesday 14 October. Next week lands on Wednesday 21st.
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=week&date=2026-10-14")
      assert %{view: "week"} = ready(lv, %{"phone" => false})
      lv |> element("#calendar-next") |> render_click()
      assert_patch(lv, "/dashboard/calendar?view=week&date=2026-10-21")

      # 1. Day opens the Monday of the week shown, not the next Wednesday.
      lv |> element("#calendar-view-day") |> render_click()
      assert_patch(lv, "/dashboard/calendar?view=day&date=2026-10-19")

      # 2. A view that starts at its date hands it on as it is.
      lv |> element("#calendar-view-month") |> render_click()
      assert_patch(lv, "/dashboard/calendar?view=month&date=2026-10-19")

      # 3. A month holding today hands over today.
      lv |> element("#calendar-view-three_day") |> render_click()
      assert_patch(lv, "/dashboard/calendar?view=three_day&date=2026-10-14")

      # 4. A month without today hands over its first, though its grid shows today.
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=month&date=2026-11-14")
      assert %{view: "month"} = ready(lv, %{"phone" => false})
      lv |> element("#calendar-view-agenda") |> render_click()
      assert_patch(lv, "/dashboard/calendar?view=agenda&date=2026-11-01")

      # 5. A week holding today hands over today.
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=week&date=2026-10-16")
      assert %{view: "week"} = ready(lv, %{"phone" => false})
      lv |> element("#calendar-view-three_day") |> render_click()
      assert_patch(lv, "/dashboard/calendar?view=three_day&date=2026-10-14")
    end
  end

  describe "agenda" do
    test "scrolls four weeks at a time to its end, and hidden calendars stay hidden", %{
      conn: conn
    } do
      %{conn: conn, integration: integration} = owner(conn)
      event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
      event(integration, "family", "Winter fair", ~U[2026-12-20 10:00:00Z])
      event(integration, "work", "Budget day", ~U[2026-12-21 10:00:00Z])
      event(integration, "work", "Spring trip", ~U[2027-03-20 10:00:00Z])

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=agenda&date=2026-10-14")

      # 1. The first window: four weeks back, eight ahead.
      assert %{view: "agenda", range: %{from: "2026-09-16", to: "2026-12-09"}, events: first} =
               ready(lv)

      assert "Design review" in titles(first)
      refute "Budget day" in titles(first)
      assert has_element?(lv, "#calendar-view-agenda[aria-pressed='true']")
      assert lv |> element("#calendar-period-title") |> render() =~ "From Wed 14 Oct"

      # 2. Hide Family before scrolling on.
      lv |> element("#calendar-rail [data-calendar-id='family']") |> render_click()
      assert_push_event(lv, "calendar:events", %{reset: true})

      # 3. The sentinel asks for the next chunk after the last loaded day.
      assert %{
               payload: %{
                 view: "agenda",
                 reset: false,
                 range: %{from: "2026-12-09", to: "2027-01-06"},
                 events: chunk
               },
               done: false
             } = more(lv, "2026-12-08")

      assert "Budget day" in titles(chunk)
      refute "Winter fair" in titles(chunk)

      # 4. On to the cap: 24 weeks from the agenda's date.
      assert %{payload: %{range: %{to: "2027-02-03"}}, done: false} = more(lv, "2027-01-05")
      assert %{payload: %{range: %{to: "2027-03-03"}}, done: false} = more(lv, "2027-02-02")

      assert %{
               payload: %{range: %{from: "2027-03-03", to: "2027-03-31"}, events: last},
               done: true
             } = more(lv, "2027-03-02")

      assert "Spring trip" in titles(last)

      # 5. Past the cap nothing more loads.
      assert %{payload: nil, done: true} = more(lv, "2027-03-30")

      # 6. Outside the agenda the event answers nothing.
      lv |> element("#calendar-view-week") |> render_click()
      assert_patch(lv, "/dashboard/calendar?view=week&date=2026-10-14")
      assert %{payload: nil} = more(lv, "2026-12-08")
    end
  end

  describe "phone" do
    test "a week shows as 3 days, and the tabs and the header move between views", %{conn: conn} do
      %{conn: conn, user: user, integration: integration} = owner(conn)
      event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])

      {:ok, lv, _html} = live(phone_conn(conn), ~p"/dashboard/calendar?view=week&date=2026-10-14")

      # 1. The hook says it is on a phone: the week shows as 3 days.
      assert %{
               view: "three_day",
               date: "2026-10-14",
               range: %{from: "2026-10-11", to: "2026-10-20"}
             } = ready(lv, %{"phone" => true})

      assert has_element?(lv, "#calendar-tab-three_day[aria-current='page']")
      assert lv |> element("#calendar-phone-title") |> render() =~ "14 to 16 Oct"

      # 2. Widening the window brings the week back; narrowing it, 3 days.
      hook(lv, "calendar:viewport", %{"phone" => false})
      assert_push_event(lv, "calendar:events", %{view: "week", date: "2026-10-14"})
      assert has_element?(lv, "#calendar-view-week[aria-pressed='true']")

      hook(lv, "calendar:viewport", %{"phone" => true})
      assert_push_event(lv, "calendar:events", %{view: "three_day", date: "2026-10-14"})

      # The stored default was never written.
      assert CalendarPreferencesQueries.get_or_create(user.id).default_view == "week"

      # 3. The header's next steps by 3 days; the URL now holds what is shown.
      lv |> element("#calendar-phone-next") |> render_click()
      assert_patch(lv, "/dashboard/calendar?view=three_day&date=2026-10-17")

      # 4. The Month tab.
      lv |> element("#calendar-tab-month") |> render_click()
      assert_patch(lv, "/dashboard/calendar?view=month&date=2026-10-17")
      assert_push_event(lv, "calendar:events", %{view: "month", date: "2026-10-17"})
      assert has_element?(lv, "#calendar-tab-month[aria-current='page']")
      refute has_element?(lv, "#calendar-tab-three_day[aria-current='page']")
      assert lv |> element("#calendar-phone-title") |> render() =~ "Oct 2026"
      assert has_element?(lv, "#calendar-phone-prev[aria-label='Previous month']")
      assert has_element?(lv, "#calendar-phone-next[aria-label='Next month']")

      # 5. A day tapped in the month selects it; the month is already loaded.
      hook(lv, "calendar:goto", %{"view" => "month", "date" => "2026-10-22"})
      assert_patch(lv, "/dashboard/calendar?view=month&date=2026-10-22")
      assert_push_event(lv, "calendar:period", %{view: "month", date: "2026-10-22"})

      # 6. The Agenda tab starts from the selected day.
      lv |> element("#calendar-tab-agenda") |> render_click()
      assert_patch(lv, "/dashboard/calendar?view=agenda&date=2026-10-22")
      assert has_element?(lv, "#calendar-tab-agenda[aria-current='page']")
      assert lv |> element("#calendar-phone-title") |> render() =~ "From 22 Oct"
    end

    test "the 3 days tab, tapped while a week is shown, moves to 3 days", %{conn: conn} do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=week&date=2026-10-14")
      assert %{view: "week"} = ready(lv, %{"phone" => false})

      lv |> element("#calendar-tab-three_day") |> render_click()
      assert_patch(lv, "/dashboard/calendar?view=three_day&date=2026-10-14")
      assert_push_event(lv, "calendar:events", %{view: "three_day", date: "2026-10-14"})
      assert has_element?(lv, "#calendar-tab-three_day[aria-current='page']")
    end

    test "the first paint already shows 3 days to a phone, and both chromes are rendered", %{
      conn: conn
    } do
      %{conn: conn} = owner(conn)
      path = ~p"/dashboard/calendar?view=week&date=2026-10-14"

      phone = conn |> put_req_header("user-agent", @iphone) |> get(path) |> html_response(200)
      desktop = conn |> put_req_header("user-agent", @desktop) |> get(path) |> html_response(200)

      assert phone =~ ~r/id="calendar-canvas"[^>]*data-view="three_day"/
      assert desktop =~ ~r/id="calendar-canvas"[^>]*data-view="week"/

      # CSS decides which chrome shows, so the server renders both to everyone.
      for html <- [phone, desktop] do
        assert html =~ ~s(id="calendar-toolbar")
        assert html =~ ~s(id="calendar-phone-header")
        assert html =~ ~s(id="calendar-tabs")
        assert html =~ ~s(id="calendar-fab")
      end
    end

    test "hide a calendar from the Calendars sheet, bring it back, and pick a date", %{conn: conn} do
      %{conn: conn, integration: integration} = owner(conn)
      event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
      event(integration, "family", "School run", ~U[2026-10-15 07:30:00Z])

      {:ok, lv, _html} =
        live(phone_conn(conn), ~p"/dashboard/calendar?view=three_day&date=2026-10-14")

      assert %{events: events} = ready(lv, %{"phone" => true})
      assert "School run" in titles(events)
      refute has_element?(lv, "#calendar-calendars-sheet")

      # 1. The header's Calendars button opens the sheet.
      lv |> element("#calendar-phone-calendars") |> render_click()
      assert has_element?(lv, "#calendar-calendars-sheet[style*='display: flex']")

      # 2. Hide Family: its events leave, and the header says one is hidden.
      lv |> element("#calendar-calendars-sheet [data-calendar-id='family']") |> render_click()
      assert_push_event(lv, "calendar:events", %{reset: true, events: filtered})
      refute "School run" in titles(filtered)
      assert has_element?(lv, "#calendar-phone-calendars", "1 hidden")

      # 3. Show all brings it back and the header is quiet again.
      lv |> element("#calendar-sheet-show-all") |> render_click()
      assert_push_event(lv, "calendar:events", %{reset: true, events: restored})
      assert "School run" in titles(restored)
      refute has_element?(lv, "#calendar-phone-calendars", "hidden")

      # 4. The same button closes the sheet.
      lv |> element("#calendar-phone-calendars") |> render_click()
      refute has_element?(lv, "#calendar-calendars-sheet")

      # 5. The title opens the date sheet; a day moves there and closes it.
      lv |> element("#calendar-phone-title") |> render_click()
      assert has_element?(lv, "#calendar-date-sheet[style*='display: flex']")

      lv |> element("#calendar-sheet-month button", ~r/^\s*22\s*$/) |> render_click()
      assert_patch(lv, "/dashboard/calendar?view=three_day&date=2026-10-22")
      refute has_element?(lv, "#calendar-date-sheet")
    end

    test "between 640 and 767px the toolbar's Calendars button opens the same sheet", %{
      conn: conn
    } do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=week&date=2026-10-14")
      assert %{view: "week"} = ready(lv, %{"phone" => false})

      lv |> element("#calendar-calendars-button") |> render_click()
      assert has_element?(lv, "#calendar-calendars-sheet[style*='display: flex']")
      assert has_element?(lv, "#calendar-calendars-sheet [data-calendar-id='family']")
    end
  end
end
