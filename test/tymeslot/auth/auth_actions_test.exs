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

  describe "validate_signup_input/1" do
    test "returns sanitized data for valid signup input" do
      params = %{
        "email" => " Test@Example.com ",
        "password" => "ValidPassword123!",
        "password_confirmation" => "ValidPassword123!",
        "full_name" => " Test User ",
        "terms_accepted" => "true"
      }

      assert {:ok, valid} = AuthActions.validate_signup_input(params)
      assert valid["email"] == "Test@Example.com"
      assert valid["full_name"] == "Test User"
    end

    test "returns error when email format is invalid" do
      params = %{
        "email" => "not-an-email",
        "password" => "ValidPassword123!",
        "password_confirmation" => "ValidPassword123!",
        "full_name" => "Test User",
        "terms_accepted" => "true"
      }

      assert {:error, %{email: _msg}} = AuthActions.validate_signup_input(params)
    end

    test "does not enforce terms_accepted (terms validation moved to Registration)" do
      params = %{
        "email" => "test@example.com",
        "password" => "ValidPassword123!",
        "password_confirmation" => "ValidPassword123!",
        "full_name" => "Test User",
        "terms_accepted" => "false"
      }

      assert {:ok, _result} = AuthActions.validate_signup_input(params)
    end
  end

  describe "validate_signup_input/1 — field length boundaries" do
    test "accepts email of exactly 254 characters" do
      # 242 'a' + "@example.com" (12) = 254 chars
      email = String.duplicate("a", 242) <> "@example.com"

      params = %{
        "email" => email,
        "password" => "ValidPass1!",
        "full_name" => "Test User"
      }

      assert {:ok, _result} = AuthActions.validate_signup_input(params)
    end

    test "rejects email of 255 characters" do
      # 243 'a' + "@example.com" (12) = 255 chars
      email = String.duplicate("a", 243) <> "@example.com"

      params = %{
        "email" => email,
        "password" => "ValidPass1!",
        "full_name" => "Test User"
      }

      assert {:error, %{email: _msg}} = AuthActions.validate_signup_input(params)
    end

    test "accepts password of exactly 80 characters" do
      # "ValidPass1!" (11) + 69 'a' = 80 chars; passes all complexity rules
      password = "ValidPass1!" <> String.duplicate("a", 69)

      params = %{
        "email" => "test@example.com",
        "password" => password,
        "full_name" => "Test User"
      }

      assert {:ok, _result} = AuthActions.validate_signup_input(params)
    end

    test "rejects password of 81 characters" do
      # "ValidPass1!" (11) + 70 'a' = 81 chars
      password = "ValidPass1!" <> String.duplicate("a", 70)

      params = %{
        "email" => "test@example.com",
        "password" => password,
        "full_name" => "Test User"
      }

      assert {:error, %{password: _msg}} = AuthActions.validate_signup_input(params)
    end

    test "accepts full_name of exactly 100 characters" do
      full_name = String.duplicate("a", 100)

      params = %{
        "email" => "test@example.com",
        "password" => "ValidPass1!",
        "full_name" => full_name
      }

      assert {:ok, _result} = AuthActions.validate_signup_input(params)
    end

    test "rejects full_name of 101 characters" do
      full_name = String.duplicate("a", 101)

      params = %{
        "email" => "test@example.com",
        "password" => "ValidPass1!",
        "full_name" => full_name
      }

      assert {:error, %{full_name: _msg}} = AuthActions.validate_signup_input(params)
    end
  end

  describe "validate_login_input/1" do
    test "sanitizes email and passes through valid login input" do
      params = %{"email" => " TEST@example.com ", "password" => "SomePassword123!"}

      assert {:ok, valid} = AuthActions.validate_login_input(params)
      assert valid["email"] == "TEST@example.com"
    end

    test "returns error for blank password" do
      params = %{"email" => "test@example.com", "password" => ""}

      assert {:error, %{password: "can't be blank"}} =
               AuthActions.validate_login_input(params)
    end

    test "returns error for missing password key" do
      assert {:error, %{password: "can't be blank"}} =
               AuthActions.validate_login_input(%{"email" => "test@example.com"})
    end
  end

  describe "validate_password_reset_input/1" do
    test "accepts valid password reset input" do
      params = %{
        "password" => "NewValidPassword123!",
        "password_confirmation" => "NewValidPassword123!"
      }

      assert {:ok, _result} = AuthActions.validate_password_reset_input(params)
    end

    test "returns error for password mismatch" do
      params = %{
        "password" => "NewValidPassword123!",
        "password_confirmation" => "DifferentPassword123!"
      }

      assert {:error, %{password_confirmation: "Password confirmation does not match"}} =
               AuthActions.validate_password_reset_input(params)
    end

    test "returns error for weak password" do
      params = %{
        "password" => "weak",
        "password_confirmation" => "weak"
      }

      assert {:error, %{password: "Password must be at least 8 characters long"}} =
               AuthActions.validate_password_reset_input(params)
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
