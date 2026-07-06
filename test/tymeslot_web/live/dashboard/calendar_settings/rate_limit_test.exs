defmodule TymeslotWeb.Dashboard.CalendarSettings.RateLimitTest do
  @moduledoc """
  Tests that the calendar settings component correctly handles rate-limit
  exhaustion for discovery and connection testing. Runs with `async: false`
  because rate-limit state lives in a shared ETS table.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :live
  @moduletag :security

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Security.RateLimiter

  setup :setup_dashboard_user

  setup do
    RateLimiter.clear_all()
    :ok
  end

  describe "discover_calendars rate limit" do
    test "shows error when calendar discovery rate limit is exceeded", %{conn: conn, user: user} do
      # Pre-exhaust the per-user discovery limit (30 per 10 minutes)
      for _i <- 1..30 do
        RateLimiter.check_calendar_discovery_rate_limit(user.id)
      end

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=calendars")

      # Open the CalDAV config form via its picker option.
      view
      |> element("button[phx-click='connect_provider'][phx-value-provider='caldav']")
      |> render_click()

      # Submit the discovery form — should be rate-limited
      view
      |> form("form[phx-submit='discover_calendars']", %{
        integration: %{
          url: "https://cal.example.com",
          username: "user",
          password: "pass",
          provider: "caldav"
        }
      })
      |> render_submit()

      assert render(view) =~ "reached the limit"
    end
  end

  describe "test_connection rate limit" do
    test "rate limiter rejects after bucket is exhausted", %{user: user} do
      _integration = insert(:calendar_integration, user: user, is_active: true)

      # Exhaust the per-user connection test limit (20 per 10 minutes)
      for _i <- 1..20 do
        assert :ok = RateLimiter.check_caldav_connection_rate_limit(user.id)
      end

      # The next call must be rejected
      assert {:error, :rate_limited, message} =
               RateLimiter.check_caldav_connection_rate_limit(user.id)

      assert message =~ "reached the limit"
    end
  end
end
