defmodule TymeslotWeb.Dashboard.CalendarGridComponentTest do
  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  describe "navigation" do
    test "renders calendar grid page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard/calendar")
      assert html =~ "Calendar"
    end

    test "shows current week period label containing the current year", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard/calendar")
      assert html =~ to_string(Date.utc_today().year)
    end
  end

  describe "view switching" do
    test "switches to day view", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("button", "Day") |> render_click()
      assert html =~ Calendar.strftime(Date.utc_today(), "%A")
    end

    test "switches back to week view after day view", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("button", "Day") |> render_click()
      html = lv |> element("button", "Week") |> render_click()
      # Week view shows short day names, not the full "DayName, Month Day, Year" format
      refute html =~ Calendar.strftime(Date.utc_today(), "%A, %B %-d, %Y")
    end
  end

  describe "date navigation" do
    test "navigates to next week and changes period label", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/dashboard/calendar")
      original_label = extract_period_label(html)
      new_html = lv |> element("button[aria-label='Next period']") |> render_click()
      refute extract_period_label(new_html) == original_label
    end

    test "navigates to previous week and changes period label", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/dashboard/calendar")
      original_label = extract_period_label(html)
      new_html = lv |> element("button[aria-label='Previous period']") |> render_click()
      refute extract_period_label(new_html) == original_label
    end

    test "today button returns to current week", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/dashboard/calendar")
      original_label = extract_period_label(html)
      lv |> element("button[aria-label='Next period']") |> render_click()
      returned_html = lv |> element("button", "Today") |> render_click()
      assert extract_period_label(returned_html) == original_label
    end
  end

  describe "refresh" do
    test "shows refresh button", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard/calendar")
      assert html =~ "Refresh"
    end
  end

  describe "month view" do
    test "renders month grid", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("button", "Month") |> render_click()
      assert html =~ "calendar-month-grid"
      assert html =~ to_string(Date.utc_today().year)
    end

    test "clicking a day cell navigates to day view", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("button", "Month") |> render_click()
      today_iso = Date.to_iso8601(Date.utc_today())

      html =
        lv
        |> element("[phx-click='navigate_to_day'][phx-value-date='#{today_iso}']")
        |> render_click()

      assert html =~ Calendar.strftime(Date.utc_today(), "%A, %B")
    end
  end

  describe "swipe navigation" do
    test "navigate_swipe 'next' advances to next day", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("button", "Day") |> render_click()
      html = render(lv)
      original_label = extract_period_label(html)

      lv
      |> element("#calendar-grid")
      |> render_hook("navigate_swipe", %{"direction" => "next"})

      new_label = extract_period_label(render(lv))
      refute new_label == original_label
    end

    test "navigate_swipe 'prev' goes back one day", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("button", "Day") |> render_click()
      html = render(lv)
      original_label = extract_period_label(html)

      lv
      |> element("#calendar-grid")
      |> render_hook("navigate_swipe", %{"direction" => "prev"})

      new_label = extract_period_label(render(lv))
      refute new_label == original_label
    end
  end

  # Extracts the text content of the first <h2> element found in HTML.
  defp extract_period_label(html) do
    case Regex.run(~r/<h2[^>]*>(.*?)<\/h2>/s, html) do
      [_match, text] -> String.trim(text)
      _no_match -> ""
    end
  end
end
