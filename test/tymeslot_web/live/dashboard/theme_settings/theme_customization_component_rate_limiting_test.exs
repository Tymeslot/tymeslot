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

    test "denies every concurrent hit once the window is already full", %{user_id: user_id} do
      # Fill the window sequentially first. Hammer's ETS sliding window
      # inserts a hit before it counts the window, so how far a concurrent
      # burst overshoots the 150 limit varies with scheduling and does not
      # hold on a CI runner. Past the limit there is no race left to lose.
      for _i <- 1..150 do
        assert :ok = RateLimiter.check_theme_customization_rate_limit(user_id)
      end

      results =
        1..200
        |> Enum.map(fn _i ->
          Task.async(fn -> RateLimiter.check_theme_customization_rate_limit(user_id) end)
        end)
        |> Task.await_many(10_000)

      # Every hit is accounted for, and none of them was let through.
      assert length(results) == 200
      assert Enum.reject(results, &match?({:error, :rate_limited, _message}, &1)) == []
    end

    # The per-user assertions live inside the shared helper
    # `RateLimiterTestHelpers.test_multiple_users_operate_independently/3`.
    # credo:disable-for-next-line Jump.CredoChecks.TestHasNoAssertions
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
