defmodule Tymeslot.Security.RateLimiterFailedLoginTest do
  @moduledoc false

  use Tymeslot.DataCase, async: false

  @moduletag :security
  @moduletag :auth

  alias Tymeslot.Security.RateLimit
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Test.LogCapture

  @ip "198.51.100.40"
  @window_ms 3_600_000

  defp unique_email(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}@example.com"

  defp fail(email, ip \\ @ip), do: RateLimiter.record_auth_attempt(email, ip, false)

  # The pre-check answers with the throttle's own sentence, distinct from the
  # per-pair budget's "You've reached the limit of ..." refusal.
  defp throttled?(email, ip \\ @ip) do
    case RateLimiter.check_auth_rate_limit(email, ip) do
      {:error, :rate_limited, message} -> message =~ "Too many failed attempts"
      :ok -> false
    end
  end

  # The expiry, in microseconds, of every hit the rate limiter holds for one
  # failed-login key.
  defp failure_rows(email, ip) do
    for {_inserted_at, expires_at} <- RateLimit.entries("login_fail:#{email}|#{ip}"),
        do: expires_at
  end

  describe "per-key state" do
    # Credential stuffing touches a fresh (email, address) pair on almost
    # every request. Each failure must land in the rate limiter's table with
    # an expiry inside the window, so its periodic clean drops it, rather
    # than in a table of its own where only a successful login would ever
    # remove the row.
    test "failures across many distinct pairs all expire within the window" do
      run = System.unique_integer([:positive])
      emails = for i <- 1..50, do: "stuffing-#{run}-#{i}@example.com"
      horizon = RateLimit.now() + @window_ms * 1000

      Enum.each(emails, &fail/1)

      rows = Enum.flat_map(emails, &failure_rows(&1, @ip))
      assert length(rows) == 50
      assert Enum.reject(rows, &(&1 <= horizon + 1_000_000)) == []

      assert :ets.whereis(:account_lockout_table) == :undefined
      refute Process.whereis(Tymeslot.Security.AccountLockout.TableOwner)
    end
  end

  describe "throttle" do
    test "the tenth failure inside the hour is itself throttled" do
      email = unique_email("tenth")

      for _i <- 1..9, do: assert(:ok = fail(email))
      refute throttled?(email)

      assert {:error, :account_throttled, message} = fail(email)
      assert message =~ "Too many failed attempts"
      assert throttled?(email)
    end

    test "stays throttled, and only throttled, well past the threshold" do
      email = unique_email("past")

      for _i <- 1..40, do: fail(email)

      assert {:error, :account_throttled, _message} = fail(email)
      assert throttled?(email)
    end

    test "a successful login clears the failures" do
      email = unique_email("clear")

      for _i <- 1..10, do: fail(email)
      assert throttled?(email)

      assert :ok = RateLimiter.record_auth_attempt(email, @ip, true)
      assert failure_rows(email, @ip) == []
      refute throttled?(email)
      assert :ok = fail(email)
    end

    test "case and whitespace variants of the email share one counter" do
      email = unique_email("variants")

      for variant <- [email, String.upcase(email), " #{email} "], _i <- 1..3 do
        assert :ok = fail(variant)
      end

      assert {:error, :account_throttled, _message} = fail("  #{String.upcase(email)}")
    end

    test "failures from one address leave the same email open from another" do
      email = unique_email("pair")

      for _i <- 1..10, do: fail(email, "198.51.100.41")

      assert throttled?(email, "198.51.100.41")
      refute throttled?(email, "198.51.100.42")
    end
  end

  describe "failed-attempt logging" do
    # This line fires on every failed attempt, so it is the highest-volume
    # identifier in the auth path; it must never carry the raw address.
    test "masks the email" do
      email = unique_email("lockout-log")

      LogCapture.with_capture([logger_level: :info], fn -> fail(email) end)

      event = LogCapture.await_log("Failed attempt recorded")
      assert LogCapture.user_metadata(event).identifier_masked == "l***@example.com"
      refute LogCapture.dump(event) =~ email
    end
  end
end
