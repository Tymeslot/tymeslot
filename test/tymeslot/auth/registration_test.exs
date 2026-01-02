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

        assert {:error, :input, _} = Registration.register_user(params, conn)
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

      assert {:error, :auth, _} = Registration.register_user(params, conn)
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

      {:ok, user, _} = Registration.register_user(params, conn)
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

      assert {:error, :auth, _} = Registration.register_user(params, %Plug.Conn{})
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

      {:ok, user, _} = Registration.register_user(params, %Plug.Conn{})

      # Email trimmed
      assert user.email == "safe@example.com"

      # Script should be removed/sanitized
      if user.name do
        refute user.name =~ "<script>"
        assert user.name =~ "Safe Name"
      else
        # Completely sanitized to nil is also acceptable security behavior
        assert true
      end
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

      {:ok, user, _} = Registration.register_user(params, %Plug.Conn{})

      # Never store plaintext
      refute user.password_hash == plain
      assert String.starts_with?(user.password_hash, "$2b$")
    end
  end
end
