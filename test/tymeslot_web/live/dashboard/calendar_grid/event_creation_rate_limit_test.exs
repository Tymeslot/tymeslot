defmodule TymeslotWeb.Dashboard.CalendarGrid.EventCreationRateLimitTest do
  @moduledoc """
  Tests that the calendar event edit rate limit correctly blocks after
  the bucket is exhausted. Runs with `async: false` because rate-limit
  state lives in a shared ETS table.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :calendar
  @moduletag :security

  import Tymeslot.DashboardTestHelpers

  alias Tymeslot.Security.RateLimiter

  setup :setup_dashboard_user

  setup do
    RateLimiter.clear_all()
    :ok
  end

  test "rate limiter rejects event edits after bucket is exhausted", %{user: user} do
    # Exhaust the per-user edit limit (30 per 5 minutes)
    for _i <- 1..30 do
      assert :ok = RateLimiter.check_calendar_event_edit_rate_limit(user.id)
    end

    # The next call must be rejected
    assert {:error, :rate_limited, message} =
             RateLimiter.check_calendar_event_edit_rate_limit(user.id)

    assert message =~ "reached the limit"
  end
end
