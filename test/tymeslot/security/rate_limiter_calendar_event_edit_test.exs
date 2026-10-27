defmodule Tymeslot.Security.RateLimiterCalendarEventEditTest do
  use ExUnit.Case, async: false

  @moduletag :security

  alias Tymeslot.Security.RateLimiter

  setup do
    RateLimiter.clear_all()
    :ok
  end

  # ---------------------------------------------------------------------------
  # check(:calendar_event_edit, _) — 30 per 5 minutes
  # ---------------------------------------------------------------------------

  describe "check(:calendar_event_edit, _)" do
    test "allows edits under the limit" do
      assert :ok = RateLimiter.check(:calendar_event_edit, 99_001)
    end

    test "rejects after 30 edits in 5 minutes" do
      user_id = 99_002

      for _i <- 1..30 do
        assert :ok = RateLimiter.check(:calendar_event_edit, user_id)
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check(:calendar_event_edit, user_id)

      assert message =~ "calendar event edit"
    end

    test "rejects invalid user_id" do
      assert {:error, :invalid_user_id} =
               RateLimiter.check(:calendar_event_edit, -1)
    end
  end

  # ---------------------------------------------------------------------------
  # check(:calendar_webhook, _) — rejects non-positive integration ids
  # ---------------------------------------------------------------------------

  describe "check(:calendar_webhook, _)" do
    test "allows valid integration id" do
      assert :ok = RateLimiter.check(:calendar_webhook, 42_001)
    end

    test "rejects id=0, negative, and non-integer values instead of sharing a bucket" do
      for bad <- [0, -1, nil, "abc", 1.5] do
        assert {:error, :invalid_id} =
                 RateLimiter.check(:calendar_webhook, bad),
               "expected #{inspect(bad)} to be rejected"
      end
    end
  end
end
