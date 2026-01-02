defmodule Tymeslot.Security.RateLimiterMultiWindowTest do
  use Tymeslot.DataCase, async: true

  alias Tymeslot.Security.RateLimiter

  setup do
    :ets.delete_all_objects(:rate_limiter_table)
    :ok
  end

  describe "signup multi-window limits (email + IP)" do
    test "blocks after 3 attempts in 10 minutes and IP bucket applies across emails" do
      ip = "203.0.113.10"
      email1 = "user1@example.com"
      email2 = "user2@example.com"

      # 3 attempts allowed
      assert :ok = RateLimiter.check_signup_rate_limit(email1, ip)
      assert :ok = RateLimiter.check_signup_rate_limit(email1, ip)
      assert :ok = RateLimiter.check_signup_rate_limit(email1, ip)

      # 4th attempt with same email/ip hits 10m limit
      assert {:error, :rate_limited, _} = RateLimiter.check_signup_rate_limit(email1, ip)

      # Different email but same IP should still be blocked by IP bucket
      assert {:error, :rate_limited, _} = RateLimiter.check_signup_rate_limit(email2, ip)
    end
  end

  describe "verification resend multi-window limits (user + IP)" do
    test "blocks after 5 attempts in 1 hour" do
      user_id = "user-123"
      ip = "198.51.100.7"

      Enum.each(1..5, fn _ ->
        assert :ok = RateLimiter.check_verification_rate_limit(user_id, ip)
      end)

      assert {:error, :rate_limited, _} =
               RateLimiter.check_verification_rate_limit(user_id, ip)
    end
  end

  describe "password reset multi-window limits (email + IP)" do
    test "blocks after 5 attempts in 1 hour" do
      email = "reset@example.com"
      ip = "192.0.2.44"

      Enum.each(1..5, fn _ ->
        assert :ok = RateLimiter.check_password_reset_rate_limit(email, ip)
      end)

      assert {:error, :rate_limited, _} =
               RateLimiter.check_password_reset_rate_limit(email, ip)
    end

    test "normalizes nil IPs for password reset buckets" do
      email = "reset-nil@example.com"

      Enum.each(1..5, fn _ ->
        assert :ok = RateLimiter.check_password_reset_rate_limit(email, nil)
      end)

      assert {:error, :rate_limited, _} =
               RateLimiter.check_password_reset_rate_limit(email, nil)
    end
  end
end
