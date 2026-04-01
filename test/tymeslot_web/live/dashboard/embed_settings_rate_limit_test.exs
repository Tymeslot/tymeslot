defmodule TymeslotWeb.Live.Dashboard.EmbedSettingsRateLimitTest do
  @moduledoc """
  Tests that the embed settings component correctly handles rate-limit exhaustion
  at the UI level. Runs with `async: false` because rate-limit state lives in a
  shared ETS table that other tests clear in their setup.
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :live
  @moduletag :security

  import Tymeslot.DashboardTestHelpers

  alias Tymeslot.Security.RateLimiter

  setup :setup_dashboard_user

  setup do
    RateLimiter.clear_all()
    :ok
  end

  test "shows rate limit error after too many domain updates", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, "/dashboard/embed")
    view |> element("button#tab-security") |> render_click()

    # Exhaust the per-user rate limit (10 updates per hour)
    for _i <- 1..10 do
      RateLimiter.check_rate("embed_domain_update:#{user.id}", 60_000 * 60, 10)
    end

    # The next UI update must be rejected by the rate limiter
    view
    |> form("form", %{allowed_domains: "ratelimit-domain.com"})
    |> render_submit()

    assert render(view) =~ "Too many updates"
  end
end
