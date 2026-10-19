defmodule Tymeslot.Auth.AuthenticationLockoutAuditTest do
  @moduledoc false

  # async: false is required: SecurityLogger emits at :info while config/test.exs
  # pins the primary level to :warning, so these tests lower it globally, and one
  # of them asserts on the *absence* of an event.
  use Tymeslot.DataCase, async: false

  @moduletag :auth
  @moduletag :security

  alias Tymeslot.Auth.Authentication
  alias Tymeslot.Security.{Password, RateLimiter}
  alias Tymeslot.Test.LogCapture

  import Tymeslot.Factory

  @password "ValidPass123!"
  @opts [ip: "203.0.113.7", user_agent: "curl/8.0"]

  # The failed-login throttle lives in the rate limiter's ETS table and
  # outlives the sandbox transaction, so each test clears it on the way out.
  setup do
    user = insert(:user, password_hash: Password.hash_password(@password))
    on_exit(fn -> RateLimiter.clear_all() end)
    {:ok, user: user}
  end

  defp capture_at_info(fun) do
    LogCapture.with_capture([logger_level: :info], fun)
  end

  # Nine recorded failures leave the account one short of the throttle
  # threshold, so the next real failed login is the attempt that crosses it.
  defp prime_failures(email, count) do
    Enum.each(1..count, fn _n ->
      RateLimiter.record_auth_attempt(email, @opts[:ip], false)
    end)
  end

  describe "account lockout auditing" do
    test "logs an account_lockout event when a failed login crosses the threshold",
         %{user: user} do
      prime_failures(user.email, 9)

      capture_at_info(fn ->
        assert {:error, :invalid_password, _message} =
                 Authentication.authenticate_user(user.email, "WrongPass123!", @opts)
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "account_lockout"} = meta}}
      assert meta.lockout_type == "account_throttled"
      assert meta.user_id == user.id
      # Logged as its network: the redactor truncates every client IP.
      assert meta.ip_address == "203.0.113.0/24"
      assert meta.user_agent == "curl/8.0"
      assert meta.email_masked == "#{String.first(user.email)}***@example.com"
      refute inspect(meta) =~ user.email
    end

    test "logs no lockout for a failed login that stays below the threshold",
         %{user: user} do
      capture_at_info(fn ->
        assert {:error, :invalid_password, _message} =
                 Authentication.authenticate_user(user.email, "WrongPass123!", @opts)
      end)

      types = logged_event_types()
      assert "authentication_failure" in types
      refute "account_lockout" in types
    end

    test "logs no lockout for a successful login", %{user: user} do
      capture_at_info(fn ->
        assert {:ok, _user, _message} =
                 Authentication.authenticate_user(user.email, @password, @opts)
      end)

      types = logged_event_types()
      assert "authentication_success" in types
      refute "account_lockout" in types
    end
  end

  describe "a login refused by the rate limit" do
    test "is logged once, as a rate_limit_violation", %{user: user} do
      for _i <- 1..10, do: RateLimiter.check_auth_rate_limit(user.email, @opts[:ip])

      capture_at_info(fn ->
        assert {:error, :rate_limited, _message} =
                 Authentication.authenticate_user(user.email, @password, @opts)
      end)

      assert [line] = LogCapture.drain()
      assert LogCapture.user_metadata(line)[:event_type] == "rate_limit_violation"
    end
  end

  describe "a login for an address with no account" do
    test "is logged once, as an authentication failure naming the reason" do
      capture_at_info(fn ->
        assert {:error, :not_found, _message} =
                 Authentication.authenticate_user("nobody@example.com", @password, @opts)
      end)

      assert [line] = LogCapture.drain()
      assert LogCapture.user_metadata(line)[:event_type] == "authentication_failure"
      assert LogCapture.user_metadata(line)[:reason] == "user_not_found"
    end
  end

  defp logged_event_types do
    LogCapture.drain()
    |> Enum.map(&LogCapture.user_metadata(&1)[:event_type])
    |> Enum.reject(&is_nil/1)
  end
end
