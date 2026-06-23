defmodule TymeslotWeb.Dashboard.CalendarGrid.MiniMonthTest do
  @moduledoc """
  LiveView coverage for the mini-month date-picker popover. The user-level
  action is "click the period label, see a small month grid, pick a day to jump
  there, and step the picker month without moving the main grid".
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    _integration = insert(:calendar_integration, user: user, is_active: true)

    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  describe "mini-month popover" do
    test "clicking the period label opens the popover", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/dashboard/calendar")

      # Closed by default.
      refute html =~ ~s(id="mini-month-popover-panel")

      html =
        lv
        |> element("#mini-month-popover button[aria-haspopup='true']")
        |> render_click()

      assert html =~ ~s(id="mini-month-popover-panel")
      # Picker month defaults to the viewed month.
      this_month = Calendar.strftime(Date.utc_today(), "%B %Y")
      assert html =~ this_month
    end

    test "picking a day navigates the grid to that date and closes the popover", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#mini-month-popover button[aria-haspopup='true']")
      |> render_click()

      # The 15th of the current month is always present in the 6×7 matrix.
      target = Date.new!(Date.utc_today().year, Date.utc_today().month, 15)

      html =
        lv
        |> element(
          ~s(#mini-month-popover-panel button[phx-value-date="#{Date.to_iso8601(target)}"])
        )
        |> render_click()

      # Grid jumped to that day (day view shows the full date label).
      assert html =~ Calendar.strftime(target, "%A, %B %-d, %Y")
      # Popover closed.
      refute html =~ ~s(id="mini-month-popover-panel")
    end

    test "stepping to the previous month changes the picker month without navigating", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#mini-month-popover button[aria-haspopup='true']")
      |> render_click()

      today = Date.utc_today()
      prev_month = Date.shift(Date.new!(today.year, today.month, 1), month: -1)

      html =
        lv
        |> element("#mini-month-popover button[aria-label='Previous month']")
        |> render_click()

      # Picker month moved back, popover still open.
      assert html =~ ~s(id="mini-month-popover-panel")
      assert html =~ Calendar.strftime(prev_month, "%B %Y")

      # The main grid did NOT navigate: still week view (the day-view full-date
      # label for today is absent because we never navigated to a day).
      refute html =~ Calendar.strftime(today, "%A, %B %-d, %Y")

      # Stepping forward twice lands on next month.
      next_month = Date.shift(Date.new!(today.year, today.month, 1), month: 1)

      lv
      |> element("#mini-month-popover button[aria-label='Next month']")
      |> render_click()

      html =
        lv
        |> element("#mini-month-popover button[aria-label='Next month']")
        |> render_click()

      assert html =~ Calendar.strftime(next_month, "%B %Y")
    end
  end
end
