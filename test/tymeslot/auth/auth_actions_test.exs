defmodule Tymeslot.Auth.AuthActionsTest do
  @moduledoc """
  Tests for AuthActions module - focusing on pure functions and validation logic.
  """

  use Tymeslot.DataCase, async: false
  @moduletag :auth

  alias Tymeslot.Auth.AuthActions

  describe "convert_terms_accepted/1" do
    test "converts string 'true' to boolean true" do
      params = %{"terms_accepted" => "true", "email" => "test@test.com"}
      result = AuthActions.convert_terms_accepted(params)
      assert result["terms_accepted"] == true
    end

    test "keeps boolean true as true" do
      params = %{"terms_accepted" => true, "email" => "test@test.com"}
      result = AuthActions.convert_terms_accepted(params)
      assert result["terms_accepted"] == true
    end

    test "converts string 'on' to boolean true" do
      params = %{"terms_accepted" => "on", "email" => "test@test.com"}
      result = AuthActions.convert_terms_accepted(params)
      assert result["terms_accepted"] == true
    end

    test "converts string 'false' to boolean false" do
      params = %{"terms_accepted" => "false", "email" => "test@test.com"}
      result = AuthActions.convert_terms_accepted(params)
      assert result["terms_accepted"] == false
    end

    test "converts nil to false" do
      params = %{"terms_accepted" => nil, "email" => "test@test.com"}
      result = AuthActions.convert_terms_accepted(params)
      assert result["terms_accepted"] == false
    end

    test "converts any other value to false" do
      params = %{"terms_accepted" => "yes", "email" => "test@test.com"}
      result = AuthActions.convert_terms_accepted(params)
      assert result["terms_accepted"] == false
    end

    test "defaults to false when key is missing" do
      params = %{"email" => "test@test.com"}
      result = AuthActions.convert_terms_accepted(params)
      assert result["terms_accepted"] == false
    end

    test "preserves other keys" do
      params = %{
        "terms_accepted" => "true",
        "email" => "test@test.com",
        "name" => "Test User"
      }

      result = AuthActions.convert_terms_accepted(params)
      assert result["email"] == "test@test.com"
      assert result["name"] == "Test User"
    end
  end

  describe "register_user/2 — registration disabled" do
    test "returns error when registration is disabled" do
      original = Application.get_env(:tymeslot, :registration_enabled)
      Application.put_env(:tymeslot, :registration_enabled, false)
      on_exit(fn -> Application.put_env(:tymeslot, :registration_enabled, original) end)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{client_ip: "127.0.0.1", user_agent: "AuthActionsTest/1.0"}
      }

      assert {:error, "Registration is currently disabled."} =
               AuthActions.register_user(%{"email" => "test@example.com"}, socket)
    end
  end

  describe "register_user/2 — password auth disabled" do
    test "returns password auth error when password_auth_enabled is false" do
      original = Application.get_env(:tymeslot, :password_auth_enabled)
      Application.put_env(:tymeslot, :password_auth_enabled, false)
      on_exit(fn -> Application.put_env(:tymeslot, :password_auth_enabled, original) end)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{client_ip: "127.0.0.1", user_agent: "AuthActionsTest/1.0"}
      }

      assert {:error, "Password authentication is currently disabled."} =
               AuthActions.register_user(%{"email" => "test@example.com"}, socket)
    end

    test "password auth error takes priority over registration disabled" do
      original_password = Application.get_env(:tymeslot, :password_auth_enabled)
      original_registration = Application.get_env(:tymeslot, :registration_enabled)
      Application.put_env(:tymeslot, :password_auth_enabled, false)
      Application.put_env(:tymeslot, :registration_enabled, true)

      on_exit(fn ->
        Application.put_env(:tymeslot, :password_auth_enabled, original_password)
        Application.put_env(:tymeslot, :registration_enabled, original_registration)
      end)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{client_ip: "127.0.0.1", user_agent: "AuthActionsTest/1.0"}
      }

      assert {:error, "Password authentication is currently disabled."} =
               AuthActions.register_user(%{"email" => "test@example.com"}, socket)
    end
  end

  describe "request_password_reset/2 — password auth disabled" do
    test "returns error when password_auth_enabled is false" do
      original = Application.get_env(:tymeslot, :password_auth_enabled)
      Application.put_env(:tymeslot, :password_auth_enabled, false)
      on_exit(fn -> Application.put_env(:tymeslot, :password_auth_enabled, original) end)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{client_ip: "127.0.0.1", user_agent: "AuthActionsTest/1.0"}
      }

      assert {:error, "Password authentication is currently disabled."} =
               AuthActions.request_password_reset("test@example.com", socket)
    end
  end

  describe "reset_password/4 — password auth disabled" do
    test "returns error when password_auth_enabled is false" do
      original = Application.get_env(:tymeslot, :password_auth_enabled)
      Application.put_env(:tymeslot, :password_auth_enabled, false)
      on_exit(fn -> Application.put_env(:tymeslot, :password_auth_enabled, original) end)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{client_ip: "127.0.0.1", user_agent: "AuthActionsTest/1.0"}
      }

      assert {:error, "Password authentication is currently disabled."} =
               AuthActions.reset_password("some-token", "NewPass123!", "NewPass123!", socket)
    end
  end
end
