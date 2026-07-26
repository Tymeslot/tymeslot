defmodule Tymeslot.Auth.RegistrationTest do
  use Tymeslot.DataCase, async: true

  @moduletag :auth

  alias Tymeslot.Auth.Registration
  import Tymeslot.Factory

  describe "registration security" do
    test "enforces strong password requirements" do
      conn = %Plug.Conn{}

      weak_passwords = [
        # Too short
        "short",
        # No letters
        "12345678",
        # No numbers
        "password",
        # No special chars
        "Password1"
      ]

      Enum.each(weak_passwords, fn password ->
        params = %{
          "email" => "test#{System.unique_integer([:positive])}@example.com",
          "password" => password,
          "password_confirmation" => password,
          "name" => "Test"
        }

        assert {:error, :input, _changeset} = Registration.register_user(params, conn)
      end)
    end

    test "prevents duplicate accounts (case-insensitive)" do
      conn = %Plug.Conn{}
      insert(:user, email: "existing@example.com")

      params = %{
        "email" => "EXISTING@EXAMPLE.COM",
        "password" => "ValidPassword123!",
        "password_confirmation" => "ValidPassword123!",
        "name" => "Duplicate",
        "terms_accepted" => "true"
      }

      assert {:error, :auth, _reason} = Registration.register_user(params, conn)
    end

    test "new accounts require email verification" do
      conn = %Plug.Conn{}

      params = %{
        "email" => "new@example.com",
        "password" => "ValidPassword123!",
        "password_confirmation" => "ValidPassword123!",
        "name" => "New User",
        "terms_accepted" => "true"
      }

      {:ok, user, _conn} = Registration.register_user(params, conn)
      assert is_nil(user.verified_at)
    end
  end

  describe "oauth registration security" do
    test "oauth accounts cannot re-register with passwords" do
      oauth_user = insert(:user, email: "oauth@gmail.com", provider: "google", password_hash: nil)

      params = %{
        "email" => oauth_user.email,
        "password" => "ValidPassword123!",
        "password_confirmation" => "ValidPassword123!",
        "name" => "OAuth User",
        "terms_accepted" => "true"
      }

      assert {:error, :auth, _changeset} = Registration.register_user(params, %Plug.Conn{})
    end
  end

  describe "input sanitization" do
    test "sanitizes malicious input" do
      params = %{
        "email" => "  safe@example.com  ",
        "password" => "ValidPassword123!",
        "password_confirmation" => "ValidPassword123!",
        "name" => "<script>alert('xss')</script>Safe Name",
        "terms_accepted" => "true"
      }

      {:ok, user, _session} = Registration.register_user(params, %Plug.Conn{})

      # Email trimmed
      assert user.email == "safe@example.com"

      # Signup persists the email, the password and the terms acceptance, and
      # nothing else. A hostile "name" in the payload is dropped outright
      # rather than sanitised onto the record.
      assert is_nil(user.name)
    end
  end

  describe "admin bootstrap" do
    test "the first registered user is promoted to admin" do
      conn = %Plug.Conn{}

      params = %{
        "email" => "first@example.com",
        "password" => "ValidPassword123!",
        "password_confirmation" => "ValidPassword123!",
        "name" => "First User",
        "terms_accepted" => "true"
      }

      assert {:ok, user, _message} = Registration.register_user(params, conn)
      assert user.is_admin, "Expected the first registered user to be promoted to admin"
    end

    test "a second registered user is not promoted to admin" do
      conn = %Plug.Conn{}

      first_params = %{
        "email" => "first2@example.com",
        "password" => "ValidPassword123!",
        "password_confirmation" => "ValidPassword123!",
        "name" => "First User",
        "terms_accepted" => "true"
      }

      {:ok, _first, _flash} = Registration.register_user(first_params, conn)

      second_params = %{
        "email" => "second@example.com",
        "password" => "ValidPassword123!",
        "password_confirmation" => "ValidPassword123!",
        "name" => "Second User",
        "terms_accepted" => "true"
      }

      assert {:ok, second, _message} = Registration.register_user(second_params, conn)
      refute second.is_admin, "Expected the second registered user not to be promoted to admin"
    end
  end

  describe "password storage" do
    test "passwords are hashed before storage" do
      plain = "SecurePassword123!"

      params = %{
        "email" => "secure@example.com",
        "password" => plain,
        "password_confirmation" => plain,
        "name" => "User",
        "terms_accepted" => "true"
      }

      {:ok, user, _session} = Registration.register_user(params, %Plug.Conn{})

      # Never store plaintext
      refute user.password_hash == plain
      assert String.starts_with?(user.password_hash, "$2b$")
    end
  end
end
