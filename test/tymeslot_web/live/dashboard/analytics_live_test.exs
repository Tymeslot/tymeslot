defmodule TymeslotWeb.Dashboard.AnalyticsLiveTest do
  use TymeslotWeb.LiveCase, async: false

  @moduletag :analytics
  @moduletag :live

  import Tymeslot.DashboardTestHelpers

  alias Tymeslot.Analytics.EventQueries
  alias Tymeslot.Security.RateLimiter

  setup %{conn: conn} do
    RateLimiter.clear_all()
    setup_dashboard_user(%{conn: conn})
  end

  describe "page rendering" do
    test "renders summary cards and date-range controls", %{conn: conn, user: user} do
      seed_visit(user, "linkedin", "hash-a")

      {:ok, _view, html} = live(conn, ~p"/dashboard/analytics")

      assert html =~ "Analytics"
      assert html =~ "Visits"
      assert html =~ "Unique visitors"
      assert html =~ "Bookings"
      assert html =~ "Conversion"
      assert html =~ "7 days"
      assert html =~ "30 days"
      assert html =~ "90 days"
    end

    test "renders sources table with rows for each utm_source", %{conn: conn, user: user} do
      seed_visit(user, "linkedin", "hash-a")
      seed_visit(user, "linkedin", "hash-b")
      seed_visit(user, "twitter", "hash-c")

      {:ok, _view, html} = live(conn, ~p"/dashboard/analytics")

      assert html =~ "linkedin"
      assert html =~ "twitter"
    end

    test "switching to the 7-day range re-renders the dashboard", %{conn: conn, user: user} do
      seed_visit(user, "linkedin", "hash-a")

      {:ok, view, _html} = live(conn, ~p"/dashboard/analytics")

      html = view |> element("button[phx-value-range=\"7d\"]") |> render_click()

      assert html =~ "Analytics"
      assert html =~ "linkedin"
    end
  end

  defp seed_visit(user, utm_source, visitor_hash) do
    {:ok, _event} =
      EventQueries.insert(%{
        event_type: "booking_page_view",
        path: "/u/#{user.id}",
        user_id: user.id,
        visitor_hash: visitor_hash,
        utm_source: utm_source,
        tracking_params: %{}
      })
  end
end
