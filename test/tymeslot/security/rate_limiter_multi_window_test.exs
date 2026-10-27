defmodule Tymeslot.Security.RateLimiterMultiWindowTest do
  use Tymeslot.DataCase, async: false
  @moduletag :security

  alias Tymeslot.Security.RateLimit
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Security.RateLimiter.Limits

  describe "signup multi-window limits (email + IP)" do
    test "the IP bucket blocks after 5 attempts in 10 minutes, across emails" do
      ip = "203.0.113.10"

      for _i <- 1..5, do: assert(:ok = RateLimiter.check(:signup_ip, ip))

      assert {:error, :rate_limited, _msg} = RateLimiter.check(:signup_ip, ip)
      assert :ok = RateLimiter.check(:signup_ip, "203.0.113.11")
    end

    test "the address bucket blocks after 5 attempts in 10 minutes, per address" do
      email = "user1@example.com"

      for _i <- 1..5, do: assert(:ok = RateLimiter.check(:signup_email, email))

      assert {:error, :rate_limited, _msg} =
               RateLimiter.check(:signup_email, email)

      assert :ok = RateLimiter.check(:signup_email, "user2@example.com")
    end
  end

  describe "verification resend multi-window limits (user + IP)" do
    test "blocks after 5 attempts in 1 hour" do
      user_id = "user-123"
      ip = "198.51.100.7"

      Enum.each(1..5, fn _i ->
        assert :ok = RateLimiter.check_verification_rate_limit(user_id, ip)
      end)

      assert {:error, :rate_limited, _msg} =
               RateLimiter.check_verification_rate_limit(user_id, ip)
    end
  end

  describe "password reset multi-window limits (email + IP)" do
    test "the IP bucket blocks after 5 requests in 1 hour, across addresses" do
      ip = "192.0.2.44"

      for _i <- 1..5, do: assert(:ok = RateLimiter.check(:password_reset_ip, ip))

      assert {:error, :rate_limited, _msg} = RateLimiter.check(:password_reset_ip, ip)
      assert :ok = RateLimiter.check(:password_reset_ip, "192.0.2.45")
    end

    test "normalizes nil IPs for password reset buckets" do
      for _i <- 1..5, do: assert(:ok = RateLimiter.check(:password_reset_ip, nil))

      assert {:error, :rate_limited, _msg} = RateLimiter.check(:password_reset_ip, nil)
    end

    test "the recipient bucket blocks after 5 requests in 1 hour, per address" do
      email = "reset@example.com"

      for _i <- 1..5,
          do: assert(:ok = RateLimiter.check(:password_reset_email, email))

      assert {:error, :rate_limited, _msg} =
               RateLimiter.check(:password_reset_email, email)

      assert :ok = RateLimiter.check(:password_reset_email, "other@example.com")
    end
  end

  describe "failed-login throttle under concurrent failures" do
    test "a concurrent burst of failures engages the throttle" do
      email = "concurrent-lockout@example.com"

      tasks =
        for _i <- 1..20 do
          Task.async(fn -> RateLimiter.record_auth_attempt(email, nil, false) end)
        end

      results = Task.await_many(tasks, 10_000)

      assert Enum.any?(results, &match?({:error, :account_throttled, _}, &1))

      assert {:error, :rate_limited, message} = RateLimiter.check_auth_rate_limit(email, nil)
      assert message =~ "Too many failed attempts"
    end
  end

  describe "booking recipient multi-window limits (per attendee email)" do
    test "blocks after 5 bookings to one mailbox within the hour" do
      email = "victim@example.com"

      Enum.each(1..5, fn _i ->
        assert :ok = RateLimiter.check(:booking_recipient, email)
      end)

      assert {:error, :rate_limited, _msg} = RateLimiter.check(:booking_recipient, email)
    end

    test "the bucket is per-recipient — a different mailbox is unaffected" do
      bombed = "bombed@example.com"
      other = "other-recipient@example.com"

      Enum.each(1..6, fn _i -> RateLimiter.check(:booking_recipient, bombed) end)

      assert {:error, :rate_limited, _msg} = RateLimiter.check(:booking_recipient, bombed)
      assert :ok = RateLimiter.check(:booking_recipient, other)
    end

    test "case and whitespace variants of an address share one bucket" do
      Enum.each(1..5, fn _i ->
        assert :ok = RateLimiter.check(:booking_recipient, "Mixed.Case@Example.com")
      end)

      # A padded, lower-cased variant must not get a fresh allowance.
      assert {:error, :rate_limited, _msg} =
               RateLimiter.check(:booking_recipient, "  mixed.case@example.com  ")
    end
  end

  # One client must not be able to lock another out of an address it does not
  # own: the per-recipient buckets are charged only once the source's own
  # budget has allowed the request, and keep no count for longer than a day.
  @day_ms 24 * 60 * 60_000

  describe "per-recipient budgets" do
    test "a verification source over its own limit spends nothing of the account's budget" do
      user_id = "verification-victim"
      attacker_ip = "203.0.113.62"

      for _i <- 1..5, do: assert(:ok = RateLimiter.check(:verification_ip, attacker_ip))

      for _i <- 1..10 do
        assert {:error, :rate_limited, _msg} =
                 RateLimiter.check_verification_rate_limit(user_id, attacker_ip)
      end

      assert :ok = RateLimiter.check_verification_rate_limit(user_id, "203.0.113.63")
    end

    test "no count is kept against an address or account for longer than a day" do
      email = "recipient-window@example.com"
      user_id = "recipient-window-user"

      assert :ok = RateLimiter.check(:signup_email, email)
      assert :ok = RateLimiter.check(:password_reset_email, email)
      assert :ok = RateLimiter.check_verification_rate_limit(user_id, "203.0.113.66")
      assert :ok = RateLimiter.check(:signup_attempt_notice, user_id)
      assert :ok = RateLimiter.check(:social_signup_confirmation, email)

      for bucket <- [
            "signup:email:#{email}",
            "password_reset:email:#{email}",
            "email_verification:user:#{user_id}",
            "signup_attempt_notice:user:#{user_id}",
            "social_signup_confirmation:email:#{email}"
          ] do
        windows = windows_ms(bucket)
        assert windows != [], "no tier recorded for #{bucket}"
        assert Enum.max(windows) <= @day_ms, "#{bucket} keeps a tier longer than a day"
      end
    end
  end

  describe "window lengths" do
    # The limiter keeps its hits in node-local ETS, which every deploy clears,
    # so a window past a day promised a policy nobody enforced while holding a
    # row per hit for its whole span.
    test "no limit keeps a count for longer than a day" do
      for {name, entry} <- Limits.all() do
        RateLimiter.check(name, sample_key(entry[:scope]))
      end

      windows = all_windows_ms()
      assert length(windows) > length(Map.keys(Limits.all()))
      assert Enum.reject(windows, &(&1 <= @day_ms)) == []
    end
  end

  defp sample_key(:source), do: "203.0.113.90"
  defp sample_key(:email), do: "window@example.com"
  defp sample_key(:key), do: "window-key"
  defp sample_key(scope) when scope in [:user, :id], do: 4_242

  # The span of every hit the limiter holds under the tiers of `bucket`.
  defp windows_ms(bucket) do
    for key <- RateLimit.keys(),
        String.starts_with?(key, bucket <> ":"),
        span <- spans(key),
        do: span
  end

  defp all_windows_ms, do: Enum.flat_map(RateLimit.keys(), &spans/1)

  defp spans(key) do
    for {inserted_at, expires_at} <- RateLimit.entries(key),
        do: div(expires_at - inserted_at, 1000)
  end
end
