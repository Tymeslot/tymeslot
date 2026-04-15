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

    test "case variants of the same email share one bucket" do
      base = "case-bucket-#{System.unique_integer([:positive])}@example.com"
      upper = String.upcase(base)
      mixed = String.capitalize(base)

      # 10 allowed attempts split across three case variants should hit the
      # limit on the 11th, proving they all share one bucket.
      for email <- [base, upper, mixed, base, upper, mixed, base, upper, mixed, base] do
        assert :ok = RateLimiter.check_auth_rate_limit(email, nil)
      end

      assert {:error, :rate_limited, _msg} = RateLimiter.check_auth_rate_limit(upper, nil)
    end

    test "whitespace-padded variants share one bucket with the canonical form" do
      base = "ws-bucket-#{System.unique_integer([:positive])}@example.com"
      leading = " #{base}"
      trailing = "#{base} "
      padded_upper = "  #{String.upcase(base)}  "

      # 10 attempts spread across padded variants should exhaust the budget.
      for email <- [
            base,
            leading,
            trailing,
            padded_upper,
            base,
            leading,
            trailing,
            padded_upper,
            base,
            leading
          ] do
        assert :ok = RateLimiter.check_auth_rate_limit(email, nil)
      end

      assert {:error, :rate_limited, _msg} =
               RateLimiter.check_auth_rate_limit(trailing, nil)
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

  describe "AccountLockout integration with check_auth_rate_limit/2" do
    # Isolated AccountLockout behaviour (thresholds, durations, counts) is tested in
    # account_lockout_test.exs. This block covers only the integration point where
    # check_auth_rate_limit/2 delegates to AccountLockout before the Hammer buckets.
    test "locked account is blocked by check_auth_rate_limit" do
      email = "lockout-hammer-#{System.unique_integer([:positive])}@example.com"

      for _i <- 1..20 do
        AccountLockout.check_and_record_attempt(email, false)
      end

      assert {:error, :rate_limited, message} = RateLimiter.check_auth_rate_limit(email, nil)
      assert message =~ "locked"
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

  describe "case-normalisation across record/check boundary" do
    # Attempts are recorded via Authentication using the DB-lowercased email, but
    # check_auth receives the raw user-submitted value. Verify that a mixed-case
    # submission is still blocked when enough failures were recorded under the
    # lowercase form.
    test "mixed-case check_auth is blocked when failures were recorded lowercase" do
      base = "lockout-case-#{System.unique_integer([:positive])}@example.com"
      mixed_case = String.upcase(base)

      on_exit(fn -> AccountLockout.clear_failed_attempts(base) end)

      # Simulate the server-side recording path (uses the DB-normalised email).
      for _i <- 1..20, do: RateLimiter.record_auth_attempt(base, false)

      # The attacker now tries with the original mixed-case value.
      assert {:error, :rate_limited, message} = RateLimiter.check_auth_rate_limit(mixed_case, nil)
      assert message =~ "locked"
    end
  end
end
