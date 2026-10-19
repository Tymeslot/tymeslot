defmodule Tymeslot.Security.RateLimiterCalendarEventMoveTest do
  use ExUnit.Case, async: false

  @moduletag :security

  alias Tymeslot.Security.RateLimiter

  setup do
    RateLimiter.clear_all()
    :ok
  end

  # ---------------------------------------------------------------------------
  # check(:calendar_event_move, _) — tiered: 3/1m, 5/5m, 15/1h, 30/1d
  # ---------------------------------------------------------------------------

  describe "check(:calendar_event_move, _)" do
    test "allows moves under the burst limit" do
      user_id = 99_001

      for _i <- 1..3 do
        assert :ok = RateLimiter.check(:calendar_event_move, user_id)
      end
    end

    test "rejects after 3 moves in the 1-minute window" do
      user_id = 99_002

      for _i <- 1..3 do
        assert :ok = RateLimiter.check(:calendar_event_move, user_id)
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check(:calendar_event_move, user_id)

      assert message =~ "calendar event move"
    end

    test "different users have independent limits" do
      for _i <- 1..3 do
        assert :ok = RateLimiter.check(:calendar_event_move, 99_003)
      end

      assert {:error, :rate_limited, _message} =
               RateLimiter.check(:calendar_event_move, 99_003)

      assert :ok = RateLimiter.check(:calendar_event_move, 99_004)
    end

    test "rejects invalid user_id" do
      assert {:error, :invalid_user_id} =
               RateLimiter.check(:calendar_event_move, -1)
    end
  end
end
