defmodule Tymeslot.Security.RateLimiterThemeCustomizationTest do
  use ExUnit.Case, async: false

  import Tymeslot.RateLimiterTestHelpers

  alias Tymeslot.Security.RateLimiter

  setup do
    # Clear all rate limit data before each test
    RateLimiter.clear_all()
    :ok
  end

  describe "check_theme_customization_rate_limit/1" do
    test "allows requests within rate limit" do
      user_id = 12_345

      # Should allow 150 requests within the window
      for i <- 1..150 do
        assert :ok = RateLimiter.check_theme_customization_rate_limit(user_id),
               "Request #{i} should be allowed"
      end
    end

    test "blocks requests exceeding rate limit" do
      user_id = 12_346

      # Use up the limit
      for _i <- 1..150 do
        assert :ok = RateLimiter.check_theme_customization_rate_limit(user_id)
      end

      # 151st request should be blocked
      assert {:error, :rate_limited, message} =
               RateLimiter.check_theme_customization_rate_limit(user_id)

      assert is_binary(message)
      assert message =~ "150"
      assert message =~ "5 minutes"
    end

    test "rate limit is per-user" do
      user_id_1 = 1001
      user_id_2 = 1002

      # User 1 exhausts their limit
      for _i <- 1..150 do
        assert :ok = RateLimiter.check_theme_customization_rate_limit(user_id_1)
      end

      # User 1 should be rate limited
      assert {:error, :rate_limited, _message} =
               RateLimiter.check_theme_customization_rate_limit(user_id_1)

      # User 2 should still be allowed (different bucket)
      assert :ok = RateLimiter.check_theme_customization_rate_limit(user_id_2)
    end

    test "rate limit resets after clearing bucket" do
      user_id = 12_347

      # Exhaust the limit
      for _i <- 1..150 do
        RateLimiter.check_theme_customization_rate_limit(user_id)
      end

      assert {:error, :rate_limited, _message} =
               RateLimiter.check_theme_customization_rate_limit(user_id)

      # Clear the bucket (simulating window expiry)
      RateLimiter.clear_bucket("theme_customization:#{user_id}")

      # Should work again
      assert :ok = RateLimiter.check_theme_customization_rate_limit(user_id)
    end

    test "rejects nil user_id" do
      assert {:error, :invalid_user_id} =
               RateLimiter.check_theme_customization_rate_limit(nil)
    end

    test "rejects zero user_id" do
      assert {:error, :invalid_user_id} =
               RateLimiter.check_theme_customization_rate_limit(0)
    end

    test "rejects negative user_id" do
      assert {:error, :invalid_user_id} =
               RateLimiter.check_theme_customization_rate_limit(-1)

      assert {:error, :invalid_user_id} =
               RateLimiter.check_theme_customization_rate_limit(-999)
    end

    test "rejects non-integer user_id" do
      assert {:error, :invalid_user_id} =
               RateLimiter.check_theme_customization_rate_limit("123")

      assert {:error, :invalid_user_id} =
               RateLimiter.check_theme_customization_rate_limit(123.45)

      assert {:error, :invalid_user_id} =
               RateLimiter.check_theme_customization_rate_limit(%{id: 123})

      assert {:error, :invalid_user_id} =
               RateLimiter.check_theme_customization_rate_limit([123])
    end

    test "accepts valid positive integer user_ids" do
      assert :ok = RateLimiter.check_theme_customization_rate_limit(1)
      assert :ok = RateLimiter.check_theme_customization_rate_limit(999_999_999)
      assert :ok = RateLimiter.check_theme_customization_rate_limit(9_999_999_999)
    end

    test "rate limit error message is actionable" do
      user_id = 12_348

      # Exhaust the limit
      for _i <- 1..150 do
        RateLimiter.check_theme_customization_rate_limit(user_id)
      end

      {:error, :rate_limited, message} =
        RateLimiter.check_theme_customization_rate_limit(user_id)

      # Message should include specific details
      assert message =~ "150"
      assert message =~ "theme customization"
      assert message =~ "5 minutes"
      assert message =~ "wait"
    end

    test "logs error for invalid user_id" do
      import ExUnit.CaptureLog

      log =
        capture_log(fn ->
          RateLimiter.check_theme_customization_rate_limit(nil)
        end)

      assert log =~ "Invalid user_id for theme customization rate limit"
      assert log =~ "nil"
    end

    test "logs warning when rate limit exceeded" do
      import ExUnit.CaptureLog

      user_id = 12_349

      # Exhaust the limit
      for _i <- 1..150 do
        RateLimiter.check_theme_customization_rate_limit(user_id)
      end

      # Capture log when rate limit is exceeded
      log =
        capture_log(fn ->
          RateLimiter.check_theme_customization_rate_limit(user_id)
        end)

      assert log =~ "Rate limit exceeded"
      assert log =~ "theme customization"
      assert log =~ to_string(user_id)
    end
  end

  describe "concurrent access" do
    test "handles concurrent requests atomically" do
      user_id = 99_999

      # Spawn many concurrent tasks
      tasks =
        for _i <- 1..200 do
          Task.async(fn ->
            RateLimiter.check_theme_customization_rate_limit(user_id)
          end)
        end

      # Wait for all tasks to complete
      results = Task.await_many(tasks, 10_000)

      # Count successes
      successes = Enum.count(results, &(&1 == :ok))

      # Should allow at most 150 requests (GenServer should serialize access)
      assert successes <= 150, "Expected at most 150 successes, got #{successes}"

      # Should have blocked at least 50 requests
      failures =
        Enum.count(results, fn
          {:error, :rate_limited, _message} -> true
          _other -> false
        end)

      assert failures >= 50, "Expected at least 50 failures, got #{failures}"
    end

    test "multiple users can operate concurrently without interference" do
      user_ids = [1000, 2000, 3000, 4000, 5000]

      test_multiple_users_operate_independently(
        user_ids,
        100,
        &RateLimiter.check_theme_customization_rate_limit/1
      )
    end
  end

  describe "integration with check_with_logging helper" do
    test "produces consistent error messages across different operations" do
      user_id = 88_888

      # Exhaust theme customization limit
      for _i <- 1..150 do
        RateLimiter.check_theme_customization_rate_limit(user_id)
      end

      {:error, :rate_limited, theme_message} =
        RateLimiter.check_theme_customization_rate_limit(user_id)

      # Exhaust meeting filter limit (different operation, same user)
      for _i <- 1..100 do
        RateLimiter.check_meeting_filter_rate_limit(user_id)
      end

      {:error, :rate_limited, filter_message} =
        RateLimiter.check_meeting_filter_rate_limit(user_id)

      # Both messages should follow the same format
      assert theme_message =~ ~r/limit of \d+ .+ actions per \d+ minutes/
      assert filter_message =~ ~r/limit of \d+ .+ actions per \d+ minutes/

      # But should have different operation names
      assert theme_message =~ "theme customization"
      assert filter_message =~ "meeting filter"

      # Both should advise waiting
      assert theme_message =~ "wait"
      assert filter_message =~ "wait"
    end
  end

  describe "boundary conditions" do
    test "exactly at limit boundary" do
      user_id = 77_777

      # Use exactly 150 requests (the limit)
      for i <- 1..150 do
        assert :ok = RateLimiter.check_theme_customization_rate_limit(user_id),
               "Request #{i}/150 should succeed"
      end

      # 151st request should fail
      assert {:error, :rate_limited, _message} =
               RateLimiter.check_theme_customization_rate_limit(user_id)
    end

    test "one request under limit" do
      user_id = 77_778

      # Use 149 requests (one under limit)
      for _i <- 1..149 do
        RateLimiter.check_theme_customization_rate_limit(user_id)
      end

      # 150th request should still succeed
      assert :ok = RateLimiter.check_theme_customization_rate_limit(user_id)

      # 151st should fail
      assert {:error, :rate_limited, _message} =
               RateLimiter.check_theme_customization_rate_limit(user_id)
    end

    test "works with very large user_ids" do
      # Test with max safe integer-like values
      large_user_id = 9_223_372_036_854_775_807

      assert :ok = RateLimiter.check_theme_customization_rate_limit(large_user_id)
    end

    test "works with user_id = 1" do
      # Edge case: smallest valid user_id
      assert :ok = RateLimiter.check_theme_customization_rate_limit(1)
    end
  end
end
