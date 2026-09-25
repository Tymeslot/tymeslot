defmodule Tymeslot.Auth.PasswordFlowPolicyTest do
  @moduledoc """
  The deployment switches that close password flows, enforced by the
  `Tymeslot.Auth` entry points themselves.

    * `password_auth_enabled?() == false` closes sign-in, sign-up and both
      password reset steps; a self-hoster running an SSO-only deployment
      relies on this.
    * `registration_enabled?() == false` closes sign-up, and is the toggle a
      self-hoster flips to run a closed instance.

  A closed flow answers with the documented message and writes nothing.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :auth
  @moduletag :integration

  alias Tymeslot.Auth
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP

  @registration_disabled "Registration is currently disabled."
  @password_auth_disabled "Password authentication is currently disabled."

  setup do
    RateLimiter.clear_all()
    on_exit(fn -> RateLimiter.clear_all() end)
    :ok
  end

  describe "check_password_flow/1" do
    test "every flow is open by default" do
      for flow <- [:login, :signup, :reset], do: assert(:ok = Auth.check_password_flow(flow))
    end

    test "closed registration closes only sign-up" do
      with_flags_off([:registration_enabled], fn ->
        assert {:error, :registration_disabled, @registration_disabled} =
                 Auth.check_password_flow(:signup)

        assert :ok = Auth.check_password_flow(:login)
        assert :ok = Auth.check_password_flow(:reset)
      end)
    end

    test "closed password auth closes every flow, and wins over registration" do
      with_flags_off([:password_auth_enabled, :registration_enabled], fn ->
        for flow <- [:login, :signup, :reset] do
          assert {:error, :password_auth_disabled, @password_auth_disabled} =
                   Auth.check_password_flow(flow)
        end
      end)
    end
  end

  describe "register_user/2" do
    test "with registration disabled, answers so and writes no user" do
      with_flags_off([:registration_enabled], fn ->
        email = unique_email("closed")

        assert {:error, :registration_disabled, @registration_disabled} =
                 Auth.register_user(signup_params(email), ip: "198.51.100.90")

        refute Repo.get_by(UserSchema, email: email)
      end)
    end

    test "with password auth disabled, answers so and writes no user" do
      with_flags_off([:password_auth_enabled], fn ->
        email = unique_email("pw-off")

        assert {:error, :password_auth_disabled, @password_auth_disabled} =
                 Auth.register_user(signup_params(email), ip: "198.51.100.91")

        refute Repo.get_by(UserSchema, email: email)
      end)
    end
  end

  describe "with password auth disabled" do
    test "authenticate_user/3 refuses before looking the account up" do
      with_flags_off([:password_auth_enabled], fn ->
        assert {:error, :password_auth_disabled, @password_auth_disabled} =
                 Auth.authenticate_user(
                   "anyone@example.com",
                   "ValidPassword123!",
                   ClientIP.request_opts(%Plug.Conn{})
                 )
      end)
    end

    test "request_password_reset/2 refuses" do
      with_flags_off([:password_auth_enabled], fn ->
        assert {:error, :password_auth_disabled, @password_auth_disabled} =
                 Auth.request_password_reset(
                   "anyone@example.com",
                   ClientIP.request_opts(%Plug.Conn{})
                 )
      end)
    end

    test "reset_password/4 refuses" do
      with_flags_off([:password_auth_enabled], fn ->
        assert {:error, :password_auth_disabled, @password_auth_disabled} =
                 Auth.reset_password(
                   "some-token",
                   "NewPass123!",
                   "NewPass123!",
                   ClientIP.request_opts(%Plug.Conn{})
                 )
      end)
    end
  end

  # --- Helpers ---

  defp unique_email(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}@example.com"

  defp signup_params(email) do
    %{"email" => email, "password" => "ValidPassword123!", "terms_accepted" => "true"}
  end

  defp with_flags_off(flags, fun) do
    originals = Map.new(flags, &{&1, Application.get_env(:tymeslot, &1)})
    Enum.each(flags, &Application.put_env(:tymeslot, &1, false))

    try do
      fun.()
    after
      Enum.each(originals, fn
        {flag, nil} -> Application.delete_env(:tymeslot, flag)
        {flag, original} -> Application.put_env(:tymeslot, flag, original)
      end)
    end
  end
end
