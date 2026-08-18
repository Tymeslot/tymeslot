defmodule Tymeslot.Auth.SecurityTest do
  @moduledoc false

  use Tymeslot.DataCase, async: false

  @moduletag :auth

  alias Tymeslot.Auth
  alias Tymeslot.Auth.Authentication
  alias Tymeslot.Auth.UserTokenQueries
  alias Tymeslot.Security.{Password, Token}

  import Tymeslot.Factory

  describe "authentication security" do
    test "prevents brute force attacks through rate limiting" do
      user =
        insert(:user,
          password_hash: Password.hash_password("ValidPass123!")
        )

      # Should block after 10 failed attempts (as configured in RateLimiter)
      Enum.each(1..10, fn _attempt ->
        Auth.authenticate_user(user.email, "WrongPassword")
      end)

      # Subsequent attempts should be rate limited
      assert {:error, :rate_limit_exceeded, _message} =
               Auth.authenticate_user(user.email, "ValidPass123!")
    end
  end

  describe "session security" do
    test "password changes invalidate all user sessions" do
      user =
        insert(:user, password_hash: Password.hash_password("OldPass123!"))

      # Create multiple sessions
      sessions = insert_list(3, :user_session, user: user)

      # Change password
      {:ok, _updated_user} =
        Auth.update_user_password(user, "OldPass123!", "NewPass123!", "NewPass123!")

      # Verify all old sessions are invalid
      Enum.each(sessions, fn session ->
        assert nil == Authentication.get_user_by_session_token(session.token)
      end)
    end
  end

  describe "registration security" do
    test "enforces strong passwords" do
      weak_passwords = [
        # Too short
        "short",
        # No letters
        "12345678",
        # No numbers
        "password",
        # No lowercase
        "PASSWORD123",
        # No uppercase
        "password123"
      ]

      Enum.each(weak_passwords, fn password ->
        params = %{
          "email" => "test#{System.unique_integer([:positive])}@example.com",
          "password" => password,
          "password_confirmation" => password,
          "name" => "Test",
          "terms_accepted" => "true"
        }

        assert {:error, :input, _changeset} = Auth.register_user(params, %Plug.Conn{})
      end)
    end

    test "signup never persists a name, even when the payload supplies one" do
      # Not an XSS/sanitisation assertion: @signup_field_spec in
      # Registration doesn't validate a name field at all, and
      # create_user/1 hardcodes its attrs to email/password/terms, so
      # `user.name` is nil for every signup regardless of input. The
      # `<script>` payload here is a deliberate negative control — it proves
      # nothing is silently smuggled through an unvalidated key, not that
      # anything is sanitised.
      params = %{
        "email" => "safe@example.com",
        "password" => "ValidPass123!",
        "password_confirmation" => "ValidPass123!",
        "full_name" => "<script>alert('xss')</script>Safe Name",
        "terms_accepted" => "true"
      }

      assert {:ok, user, _message} = Auth.register_user(params, %Plug.Conn{})

      assert user.email == "safe@example.com"
      assert is_nil(user.name)
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

      {:ok, user, _session} = Auth.register_user(params, conn)
      assert is_nil(user.verified_at)
    end
  end

  describe "password reset security" do
    test "reset tokens are single-use" do
      user = insert(:user)
      assert {:ok, :reset_initiated, _message} = Auth.initiate_password_reset(user.email)

      # Get token directly using helper - initiate_password_reset sends it via email
      # For testing, we generate a fresh token and store it
      {token, _value} = Token.generate_password_reset_token()
      {:ok, _result} = UserTokenQueries.set_reset_token(user, token)

      # First use succeeds
      result = Auth.reset_password(token, "NewPass123!", "NewPass123!")
      # Should succeed (returns 3-tuple)
      assert match?({:ok, _, _}, result)

      # Second use always fails
      assert {:error, :invalid_token, _message} =
               Auth.reset_password(token, "AnotherPass123!", "AnotherPass123!")
    end
  end

  describe "account protection" do
    test "email changes require current password" do
      user =
        insert(:user, password_hash: Password.hash_password("Current123!"))

      # Wrong password blocks email change
      assert {:error, "Current password is incorrect"} =
               Auth.request_email_change(user, "new@example.com", "Wrong123!")

      # Correct password initiates email change
      assert {:ok, updated, _message} =
               Auth.request_email_change(user, "new@example.com", "Current123!")

      assert updated.pending_email == "new@example.com"
      # SHA-256 hex digest of the emailed token — the raw token is never stored.
      assert updated.email_change_token_hash =~ ~r/^[0-9a-f]{64}$/
    end

    test "password changes require current password" do
      user =
        insert(:user, password_hash: Password.hash_password("Current123!"))

      # Wrong password blocks password change
      assert {:error, _reason} =
               Auth.update_user_password(user, "Wrong123!", "New123!New", "New123!New")

      # Correct password allows password change
      assert {:ok, _updated} =
               Auth.update_user_password(user, "Current123!", "NewPass123!", "NewPass123!")
    end
  end
end
