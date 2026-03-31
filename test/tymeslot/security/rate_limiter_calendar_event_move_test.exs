defmodule Tymeslot.Security.RateLimiterCalendarEventMoveTest do
  use ExUnit.Case, async: false

  @moduletag :security

  alias Tymeslot.Security.RateLimiter

  setup do
    RateLimiter.clear_all()
    :ok
  end

  # ---------------------------------------------------------------------------
  # check_calendar_event_move_rate_limit/1 — tiered: 3/1m, 5/5m, 15/1h, 30/1d
  # ---------------------------------------------------------------------------

  describe "check_calendar_event_move_rate_limit/1" do
    test "allows moves under the burst limit" do
      user_id = 99_001

      for _ <- 1..3 do
        assert :ok = RateLimiter.check_calendar_event_move_rate_limit(user_id)
      end
    end

    test "rejects after 3 moves in the 1-minute window" do
      user_id = 99_002

      for _ <- 1..3 do
        assert :ok = RateLimiter.check_calendar_event_move_rate_limit(user_id)
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check_calendar_event_move_rate_limit(user_id)

      assert message =~ "calendar event move"
    end

    test "different users have independent limits" do
      for _ <- 1..3 do
        assert :ok = RateLimiter.check_calendar_event_move_rate_limit(99_003)
      end

      assert {:error, :rate_limited, _} =
               RateLimiter.check_calendar_event_move_rate_limit(99_003)

      assert :ok = RateLimiter.check_calendar_event_move_rate_limit(99_004)
    end

    test "rejects invalid user_id" do
      assert {:error, :invalid_user_id} =
               RateLimiter.check_calendar_event_move_rate_limit(-1)
    end
  end
end
