defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomizationRateLimitLiveTest do
  use TymeslotWeb.LiveCase, async: false
  @moduletag :utils

  import Tymeslot.DashboardTestHelpers

  alias Tymeslot.Security.RateLimiter

  setup do
    RateLimiter.clear_all()
    :ok
  end

  setup :setup_dashboard_user_with_theme

  describe "Rate limit feedback in the UI" do
    test "shows an error flash when a user exceeds the customization rate limit",
         %{conn: conn, user: user} do
      # Pre-exhaust the rate limit for this user outside the LiveView
      for _i <- 1..150,
          do: assert(:ok = RateLimiter.check_theme_customization_rate_limit(user.id))

      {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

      view
      |> element("button[phx-value-theme='1']", "Customize Style")
      |> render_click()

      view
      |> element("button[phx-click='theme:select_color_scheme'][phx-value-scheme='forest']")
      |> render_click()

      # The user should see an error flash, not a silent failure
      assert render(view) =~ "reached the limit"
    end
  end
end
