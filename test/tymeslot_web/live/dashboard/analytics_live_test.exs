defmodule TymeslotWeb.Dashboard.AnalyticsLiveTest do
  use TymeslotWeb.LiveCase, async: false

  @moduletag :analytics
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Analytics.EventQueries
  alias Tymeslot.Security.RateLimiter

  setup %{conn: conn} do
    RateLimiter.clear_all()
    setup_dashboard_user(%{conn: conn})
  end

  describe "when booking analytics is disabled" do
    setup do
      Application.put_env(:tymeslot, :booking_analytics_enabled, false)
      on_exit(fn -> Application.put_env(:tymeslot, :booking_analytics_enabled, true) end)
    end

    test "redirects away from the analytics dashboard", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/dashboard"}}} =
               live(conn, ~p"/dashboard/analytics")
    end
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

  describe "attribution table with real booking data" do
    test "shows linkedin visit count, booking count, and conversion rate", %{
      conn: conn,
      user: user
    } do
      # 4 visits with 3 distinct visitor_hashes → 3 unique visitors
      seed_visit(user, "linkedin", "hash-uv-1")
      seed_visit(user, "linkedin", "hash-uv-2")
      seed_visit(user, "linkedin", "hash-uv-3")
      seed_visit(user, "linkedin", "hash-uv-3")

      # 2 booked meetings attributed to linkedin, distinct start times to dodge
      # unique constraint. Each carries the visitor_hash of one of the viewers
      # above, so they count as 2 distinct converting visitors — conversion is
      # measured from converting visitors, not raw booking volume.
      base = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

      insert(:meeting,
        organizer_user_id: user.id,
        utm_source: "linkedin",
        visitor_hash: "hash-uv-1",
        start_time: base,
        end_time: DateTime.add(base, 60, :minute)
      )

      insert(:meeting,
        organizer_user_id: user.id,
        utm_source: "linkedin",
        visitor_hash: "hash-uv-2",
        start_time: DateTime.add(base, 3600, :second),
        end_time: DateTime.add(base, 3600 + 60 * 60, :second)
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/analytics")

      # Scope the assertions to the linkedin row so bare digits can't match
      # unrelated markup (grid classes, SVG viewBox, padding, etc.).
      row_html = view |> element("tr", "linkedin") |> render()

      assert row_html =~ "linkedin"
      # Cells in order: source, visits (4), bookings (2), conversion (66.7%)
      assert row_html =~ ~r/>\s*4\s*</
      assert row_html =~ ~r/>\s*2\s*</
      # Conversion: 2 bookings / 3 unique visitors * 100 = 66.7%
      assert row_html =~ "66.7%"
    end
  end

  describe "empty / zero-data state" do
    test "renders zeroed summary and empty-state messaging with no data", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/analytics")

      assert html =~ "Analytics"
      # Conversion with zero unique visitors is guarded to 0.0%
      assert html =~ "0.0%"
      # Both the chart and the sources table show the empty-state copy
      assert html =~ "No traffic in this period yet."
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
