defmodule Tymeslot.Auth.AuthActionsCompositionTest do
  @moduledoc """
  Composition coverage for the config-gated branches of
  `Tymeslot.Auth.AuthActions`.

  The unit suite (`auth_actions_test.exs`) covers pure helpers —
  `convert_terms_accepted/1`, validation, socket assign helpers — and the
  password-auth-disabled short-circuits on `request_password_reset/2` and
  `reset_password/4`. This file pins the signup branches, where the flag must
  also be shown to leave the database untouched:

    * `registration_enabled?() == false` blocks `register_user/2` —
      this is the toggle a self-hoster flips to run a closed instance.
    * `password_auth_enabled?() == false` blocks `register_user/2` too, and
      wins over the registration flag.

  When either flag is off the user must receive the documented message,
  and no user row may be created.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :auth
  @moduletag :integration

  alias Tymeslot.Auth.AuthActions
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

  setup do
    RateLimiter.clear_all()
    on_exit(fn -> RateLimiter.clear_all() end)
    :ok
  end

  describe "register_user/2 with registration disabled" do
    test "returns the registration-disabled message and writes no user" do
      with_flag_off(:registration_enabled, fn ->
        email = "closed-#{System.unique_integer([:positive])}@example.com"

        params = %{
          "email" => email,
          "password" => "ValidPassword123!",
          "password_confirmation" => "ValidPassword123!",
          "name" => "Closed User",
          "full_name" => "Closed User",
          "terms_accepted" => "true"
        }

        assert {:error, message} = AuthActions.register_user(params, fake_socket())
        assert message == AuthActions.registration_disabled_message()
        refute Repo.get_by(UserSchema, email: email)
      end)
    end
  end

  describe "register_user/2 with password auth disabled" do
    test "password-auth-disabled wins over registration flag" do
      # Disabling password auth should short-circuit even if registration
      # is enabled — a self-hoster running an OAuth-only deployment relies
      # on this to keep password signups closed.
      with_flag_off(:password_auth_enabled, fn ->
        email = "pw-off-#{System.unique_integer([:positive])}@example.com"

        params = %{
          "email" => email,
          "password" => "ValidPassword123!",
          "password_confirmation" => "ValidPassword123!",
          "name" => "PW Off",
          "full_name" => "PW Off",
          "terms_accepted" => "true"
        }

        assert {:error, message} = AuthActions.register_user(params, fake_socket())
        assert message == AuthActions.password_auth_disabled_message()
        refute Repo.get_by(UserSchema, email: email)
      end)
    end
  end

  # --- Helpers ---

  defp fake_socket do
    %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
  end

  defp with_flag_off(flag, fun) do
    original = Application.get_env(:tymeslot, flag)
    Application.put_env(:tymeslot, flag, false)

    try do
      fun.()
    after
      if is_nil(original),
        do: Application.delete_env(:tymeslot, flag),
        else: Application.put_env(:tymeslot, flag, original)
    end
  end
end
