defmodule Tymeslot.Auth.AuthenticationLockoutAuditTest do
  @moduledoc false

  # async: false is required: SecurityLogger emits at :info while config/test.exs
  # pins the primary level to :warning, so these tests lower it globally, and one
  # of them asserts on the *absence* of an event.
  use Tymeslot.DataCase, async: false

  @moduletag :auth
  @moduletag :security

  alias Tymeslot.Auth.Authentication
  alias Tymeslot.Security.{AccountLockout, Password, RateLimiter}
  alias Tymeslot.Test.LogCapture

  import Tymeslot.Factory

  @password "ValidPass123!"
  @opts [ip_address: "203.0.113.7", user_agent: "curl/8.0"]

  # The lockout tracker lives in ETS and outlives the sandbox transaction, so
  # each test clears its own account's attempts on the way out.
  setup do
    user = insert(:user, password_hash: Password.hash_password(@password))
    on_exit(fn -> AccountLockout.clear_failed_attempts(user.email) end)
    {:ok, user: user}
  end

  defp capture_at_info(fun) do
    LogCapture.with_capture([logger_level: :info], fun)
  end

  # Nine recorded failures leave the account one short of the throttle
  # threshold, so the next real failed login is the attempt that crosses it.
  defp prime_failures(email, count) do
    Enum.each(1..count, fn _n -> RateLimiter.record_auth_attempt(email, false) end)
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
      assert meta.ip_address == "203.0.113.7"
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

  defp logged_event_types do
    LogCapture.drain()
    |> Enum.map(&LogCapture.user_metadata(&1)[:event_type])
    |> Enum.reject(&is_nil/1)
  end
end
