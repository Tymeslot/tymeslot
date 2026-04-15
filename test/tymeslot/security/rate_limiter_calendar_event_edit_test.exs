defmodule Tymeslot.Security.RateLimiterCalendarEventEditTest do
  use ExUnit.Case, async: false

  @moduletag :security

  alias Tymeslot.Security.RateLimiter

  setup do
    RateLimiter.clear_all()
    :ok
  end

  # ---------------------------------------------------------------------------
  # check_calendar_event_edit_rate_limit/1 — 30 per 5 minutes
  # ---------------------------------------------------------------------------

  describe "check_calendar_event_edit_rate_limit/1" do
    test "allows edits under the limit" do
      assert :ok = RateLimiter.check_calendar_event_edit_rate_limit(99_001)
    end

    test "rejects after 30 edits in 5 minutes" do
      user_id = 99_002

      for _i <- 1..30 do
        assert :ok = RateLimiter.check_calendar_event_edit_rate_limit(user_id)
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check_calendar_event_edit_rate_limit(user_id)

      assert message =~ "calendar event edit"
    end

    test "rejects invalid user_id" do
      assert {:error, :invalid_user_id} =
               RateLimiter.check_calendar_event_edit_rate_limit(-1)
    end
  end

  # ---------------------------------------------------------------------------
  # check_calendar_webhook_rate_limit/1 — rejects non-positive integration ids
  # ---------------------------------------------------------------------------

  describe "check_calendar_webhook_rate_limit/1" do
    test "allows valid integration id" do
      assert :ok = RateLimiter.check_calendar_webhook_rate_limit(42_001)
    end

    test "rejects id=0, negative, and non-integer values instead of sharing a bucket" do
      for bad <- [0, -1, nil, "abc", 1.5] do
        assert {:error, :rate_limited} =
                 RateLimiter.check_calendar_webhook_rate_limit(bad),
               "expected #{inspect(bad)} to be rejected"
      end
    end
  end
end
