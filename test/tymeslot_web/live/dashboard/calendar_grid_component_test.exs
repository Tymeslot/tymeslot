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
    _integration = insert(:calendar_integration, user: user)
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
      html = lv |> element("button[phx-value-view='day']", "Day") |> render_click()
      assert html =~ Calendar.strftime(Date.utc_today(), "%A")
    end

    test "switches back to week view after day view", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("button[phx-value-view='day']", "Day") |> render_click()
      html = lv |> element("button[phx-value-view='week']", "Week") |> render_click()
      # Week view shows short day names, not the full "DayName, Month Day, Year" format
      refute html =~ Calendar.strftime(Date.utc_today(), "%A, %B %-d, %Y")
    end

    test "switches to 3-day view", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = lv |> element("button[phx-value-view='three_day']", "3 Days") |> render_click()
      # 3-day view renders exactly 3 day columns (each with data-day-col attr)
      assert length(Regex.scan(~r/data-day-col=/, html)) == 3
    end
  end

  describe "responsive view" do
    test "tablet viewport demotes week to 3-day without persisting", %{conn: conn, user: user} do
      alias Tymeslot.CalendarGrid

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#calendar-grid")
      |> render_hook("set_responsive_view", %{"viewport" => "tablet"})

      html = render(lv)
      # The 3-day view renders three day columns
      assert length(Regex.scan(~r/data-day-col=/, html)) == 3

      # But the user's stored preference remains :week
      prefs = CalendarGrid.get_or_create_preferences(user.id)
      assert prefs.default_view == "week"
    end

    test "mobile viewport demotes week to day", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#calendar-grid")
      |> render_hook("set_responsive_view", %{"viewport" => "mobile"})

      html = render(lv)
      # Day view's full date format appears
      assert html =~ Calendar.strftime(Date.utc_today(), "%A, %B %-d, %Y")
    end

    test "mobile viewport demotes three_day to day", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      # First switch to three_day
      lv |> element("button[phx-value-view='three_day']", "3 Days") |> render_click()
      assert length(Regex.scan(~r/data-day-col=/, render(lv))) == 3

      lv
      |> element("#calendar-grid")
      |> render_hook("set_responsive_view", %{"viewport" => "mobile"})

      html = render(lv)
      # Day view renders exactly 1 day column
      assert length(Regex.scan(~r/data-day-col=/, html)) == 1
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
      html = lv |> element("button[phx-value-view='month']", "Month") |> render_click()
      assert html =~ "calendar-month-grid"
      assert html =~ to_string(Date.utc_today().year)
    end

    test "clicking a day cell navigates to day view", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("button[phx-value-view='month']", "Month") |> render_click()
      today_iso = Date.to_iso8601(Date.utc_today())

      html =
        lv
        |> element("[phx-click='navigate_to_day'][phx-value-date='#{today_iso}']")
        |> render_click()

      assert html =~ Calendar.strftime(Date.utc_today(), "%A, %B")
    end
  end

  describe "handle_set_view three_day does not persist preference" do
    test "switching to three_day leaves stored default_view unchanged", %{conn: conn, user: user} do
      alias Tymeslot.CalendarGrid

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv |> element("button[phx-value-view='three_day']", "3 Days") |> render_click()

      # Three-day view must be reflected in the DOM
      html = render(lv)
      assert length(Regex.scan(~r/data-day-col=/, html)) == 3

      # But the stored preference must still be week (the factory default)
      prefs = CalendarGrid.get_or_create_preferences(user.id)
      assert prefs.default_view == "week"
    end
  end

  describe "swipe navigation" do
    test "navigate_swipe 'next' advances to next day", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("button[phx-value-view='day']", "Day") |> render_click()
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
      lv |> element("button[phx-value-view='day']", "Day") |> render_click()
      html = render(lv)
      original_label = extract_period_label(html)

      lv
      |> element("#calendar-grid")
      |> render_hook("navigate_swipe", %{"direction" => "prev"})

      new_label = extract_period_label(render(lv))
      refute new_label == original_label
    end

    test "navigate_swipe 'next' in three_day view advances by 3 days", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("button[phx-value-view='three_day']", "3 Days") |> render_click()
      original_label = extract_period_label(render(lv))

      lv
      |> element("#calendar-grid")
      |> render_hook("navigate_swipe", %{"direction" => "next"})

      new_label = extract_period_label(render(lv))
      refute new_label == original_label
    end
  end

  describe "empty state" do
    setup %{conn: conn} do
      user = insert(:user, onboarding_completed_at: DateTime.utc_now())
      _profile = insert(:profile, user: user)
      conn = conn |> Test.init_test_session(%{}) |> fetch_session()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "shows empty state with connect link when no calendars are connected", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard/calendar")
      assert html =~ "Nothing to see here"
      assert html =~ "Connect at least one calendar"
      assert html =~ "Connect a calendar"
      assert html =~ ~p"/dashboard/calendar-integration"
    end
  end

  describe "created_by_tymeslot badge" do
    setup %{conn: conn} do
      user = insert(:user, onboarding_completed_at: DateTime.utc_now())
      _profile = insert(:profile, user: user)
      integration = insert(:calendar_integration, user: user)
      conn = conn |> Test.init_test_session(%{}) |> fetch_session()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user, integration: integration}
    end

    test "renders logo badge for events created by Tymeslot", %{
      conn: conn,
      integration: integration
    } do
      _event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          created_by_tymeslot: true
        )

      {:ok, _lv, html} = live(conn, ~p"/dashboard/calendar")
      assert html =~ "logo.svg"
    end

    test "does not render logo badge for external events", %{conn: conn, integration: integration} do
      _event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          created_by_tymeslot: false
        )

      {:ok, _lv, html} = live(conn, ~p"/dashboard/calendar")
      refute html =~ "logo.svg"
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
