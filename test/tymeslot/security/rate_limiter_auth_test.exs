defmodule Tymeslot.Security.RateLimiterAuthTest do
  use Tymeslot.DataCase, async: false
  @moduletag :security

  alias Tymeslot.Security.AccountLockout
  alias Tymeslot.Security.RateLimiter

  describe "check_auth_rate_limit/2 — per-email bucket" do
    test "allows up to 10 attempts then blocks the 11th" do
      email = "brute@example.com"

      for _i <- 1..10 do
        assert :ok = RateLimiter.check_auth_rate_limit(email, nil)
      end

      assert {:error, :rate_limited, _msg} = RateLimiter.check_auth_rate_limit(email, nil)
    end

    test "different emails have independent buckets" do
      email_a = "user-a@example.com"
      email_b = "user-b@example.com"

      for _i <- 1..10 do
        RateLimiter.check_auth_rate_limit(email_a, nil)
      end

      assert {:error, :rate_limited, _msg} = RateLimiter.check_auth_rate_limit(email_a, nil)
      assert :ok = RateLimiter.check_auth_rate_limit(email_b, nil)
    end
  end

  describe "check_auth_rate_limit/2 — IP bucket" do
    test "blocks after 50 attempts from the same IP across different emails" do
      ip = "10.0.0.1"

      for i <- 1..50 do
        email = "victim#{i}@example.com"
        assert :ok = RateLimiter.check_auth_rate_limit(email, ip)
      end

      assert {:error, :rate_limited, _msg} =
               RateLimiter.check_auth_rate_limit("overflow@example.com", ip)
    end

    test "nil IP is ignored — does not contribute to or block on the IP bucket" do
      for i <- 1..10 do
        assert :ok = RateLimiter.check_auth_rate_limit("nil-ip#{i}@example.com", nil)
      end

      assert :ok = RateLimiter.check_auth_rate_limit("new@example.com", nil)
    end

    test "empty string IP is ignored" do
      for i <- 1..10 do
        assert :ok = RateLimiter.check_auth_rate_limit("empty-ip#{i}@example.com", "")
      end

      assert :ok = RateLimiter.check_auth_rate_limit("also-new@example.com", "")
    end
  end

  describe "record_auth_attempt/2" do
    test "success clears the lockout counter for the email" do
      email = "clear-on-success@example.com"

      for _i <- 1..5 do
        AccountLockout.check_and_record_attempt(email, false)
      end

      assert AccountLockout.get_failed_attempt_count(email) == 5

      RateLimiter.record_auth_attempt(email, true)

      assert AccountLockout.get_failed_attempt_count(email) == 0
    end

    test "failure increments the failed attempt counter" do
      email = "increment@example.com"

      assert AccountLockout.get_failed_attempt_count(email) == 0

      RateLimiter.record_auth_attempt(email, false)
      assert AccountLockout.get_failed_attempt_count(email) == 1

      RateLimiter.record_auth_attempt(email, false)
      assert AccountLockout.get_failed_attempt_count(email) == 2
    end
  end
end
