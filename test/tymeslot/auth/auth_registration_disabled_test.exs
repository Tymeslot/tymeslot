defmodule Tymeslot.AuthRegistrationDisabledTest do
  @moduledoc """
  Covers `Tymeslot.Auth.register_user/3` on a deployment that has closed new
  registrations.

  Split out of `Tymeslot.AuthTest`, which is `async: true`, because
  `:registration_enabled` is global Application env rather than per-test state:
  flipping it inside an async module switched registration off for every test
  running beside it, and anything rendering `/auth/signup` in that window was
  redirected to login and failed. Every other module that touches the flag is
  `async: false` for the same reason.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :auth

  alias Tymeslot.Auth

  describe "register_user/3 — registration disabled" do
    setup do
      original = Application.get_env(:tymeslot, :registration_enabled)
      Application.put_env(:tymeslot, :registration_enabled, false)
      on_exit(fn -> Application.put_env(:tymeslot, :registration_enabled, original) end)
      :ok
    end

    test "returns registration_disabled error when flag is off" do
      params = %{
        "email" => "new@example.com",
        "password" => "ValidPassword123!",
        "password_confirmation" => "ValidPassword123!",
        "name" => "New User",
        "terms_accepted" => "true"
      }

      assert {:error, :registration_disabled, "Registration is currently disabled."} =
               Auth.register_user(params, %Plug.Conn{})
    end
  end
end
