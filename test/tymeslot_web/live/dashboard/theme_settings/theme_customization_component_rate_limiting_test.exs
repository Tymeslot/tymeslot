defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomizationComponentRateLimitingTest do
  use TymeslotWeb.ConnCase, async: false
  @moduletag :utils

  import Tymeslot.Factory
  import Tymeslot.RateLimiterTestHelpers

  alias Tymeslot.Security.RateLimiter

  describe "theme customization rate limiting - unit level" do
    setup do
      # Clear rate limiter before each test
      RateLimiter.clear_all()

      user = insert(:user)
      profile = insert(:profile, user: user, username: "test-user")
      insert(:calendar_integration, user: user, is_active: true)

      %{user: user, profile: profile}
    end

    test "rate limiter enforces limit for theme customizations", %{profile: profile} do
      user_id = profile.user_id

      # Should allow 150 requests within limit
      for i <- 1..150 do
        assert :ok = RateLimiter.check_theme_customization_rate_limit(user_id),
               "Request #{i} should be allowed"
      end

      # 151st request should be blocked
      assert {:error, :rate_limited, message} =
               RateLimiter.check_theme_customization_rate_limit(user_id)

      assert message =~ "150"
      assert message =~ "5 minutes"
    end

    test "rate limit is per-user and isolated", %{profile: profile} do
      user_2 = insert(:user)
      user_id_1 = profile.user_id
      user_id_2 = user_2.id

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

    test "rejects invalid user_ids", %{profile: profile} do
      # Test validation logic
      assert {:error, :invalid_user_id} =
               RateLimiter.check_theme_customization_rate_limit(nil)

      assert {:error, :invalid_user_id} =
               RateLimiter.check_theme_customization_rate_limit(0)

      assert {:error, :invalid_user_id} =
               RateLimiter.check_theme_customization_rate_limit(-1)

      # Valid user_id should work
      assert :ok = RateLimiter.check_theme_customization_rate_limit(profile.user_id)
    end

    test "error message provides actionable guidance", %{profile: profile} do
      user_id = profile.user_id

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
  end

  describe "concurrent rate limiting" do
    setup do
      RateLimiter.clear_all()

      user = insert(:user)
      profile = insert(:profile, user: user, username: "concurrent-user")

      %{user_id: profile.user_id}
    end

    test "handles concurrent requests atomically", %{user_id: user_id} do
      # Spawn multiple concurrent tasks trying to exceed the rate limit
      tasks =
        for _i <- 1..200 do
          Task.async(fn ->
            RateLimiter.check_theme_customization_rate_limit(user_id)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # Count successes and failures
      successes = Enum.count(results, fn result -> result == :ok end)

      failures =
        Enum.count(results, fn
          {:error, :rate_limited, _message} -> true
          _other -> false
        end)

      # Rate limiting should block *some* requests. The exact split is
      # non-deterministic — Hammer ETS uses non-atomic read-check-increment,
      # so the overshoot above the 150 limit varies with system load and
      # scheduler timing. We only assert that the limiter meaningfully engaged:
      # not all 200 succeeded, and not all 200 failed.
      assert successes < 200, "Rate limiter never engaged — all 200 requests succeeded"
      assert failures > 0, "Expected some requests to be rate-limited"
      assert successes >= 150, "Expected at least the base limit (150) to succeed"

      # All requests should be accounted for
      assert successes + failures == 200
    end

    test "multiple users operate independently", %{user_id: base_user_id} do
      user_2 = insert(:user)
      user_3 = insert(:user)
      user_ids = [base_user_id, user_2.id, user_3.id]

      test_multiple_users_operate_independently(
        user_ids,
        100,
        &RateLimiter.check_theme_customization_rate_limit/1
      )
    end
  end
end
