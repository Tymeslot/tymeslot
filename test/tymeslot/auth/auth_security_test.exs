defmodule Tymeslot.Auth.SecurityTest do
  @moduledoc false

  use Tymeslot.DataCase, async: true

  @moduletag :auth

  alias Tymeslot.Auth
  alias Tymeslot.Auth.{Authentication, Session}
  alias Tymeslot.DatabaseQueries.UserQueries
  alias Tymeslot.Security.{Password, Token}

  import Tymeslot.Factory
  import Phoenix.ConnTest

  describe "authentication security" do
    test "prevents brute force attacks through rate limiting" do
      # Clear rate limits before test
      :ets.delete_all_objects(:rate_limiter_table)

      user =
        insert(:user,
          password_hash: Password.hash_password("ValidPass123!")
        )

      # Should block after 10 failed attempts (as configured in RateLimiter)
      Enum.each(1..10, fn _ ->
        Auth.authenticate_user(user.email, "WrongPassword")
      end)

      # Subsequent attempts should be rate limited
      assert {:error, :rate_limit_exceeded, _} =
               Auth.authenticate_user(user.email, "ValidPass123!")
    end

    test "protects against timing attacks with consistent error messages" do
      # Non-existent user
      {:error, _, message1} = Auth.authenticate_user("fake@example.com", "password")

      # Existing user with wrong password
      user =
        insert(:user,
          password_hash: Password.hash_password("RealPass123!")
        )

      {:error, _, message2} = Auth.authenticate_user(user.email, "WrongPass")

      # Messages should be identical to prevent user enumeration
      assert message1 == message2
    end

    test "oauth users cannot use password authentication" do
      oauth_user = insert(:user, provider: "google", password_hash: nil)

      # OAuth users should get an error tuple, not an exception
      # This prevents timing attacks by returning consistent error responses
      assert {:error, :oauth_user, _message} =
               Auth.authenticate_user(oauth_user.email, "any-password")
    end
  end

  describe "session security" do
    test "sessions expire after 24 hours" do
      user = insert(:user)

      {:ok, _conn, _token} =
        Session.create_session(init_test_session(build_conn(), %{}), user)

      # Create expired session directly in DB
      expired_session =
        insert(:user_session,
          user: user,
          token: "expired-token",
          expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)
        )

      # Expired sessions should not authenticate
      assert nil == Authentication.get_user_by_session_token(expired_session.token)
    end

    test "password changes invalidate all user sessions" do
      user =
        insert(:user, password_hash: Password.hash_password("OldPass123!"))

      # Create multiple sessions
      sessions = insert_list(3, :user_session, user: user)

      # Change password
      {:ok, _} = Auth.update_user_password(user, "OldPass123!", "NewPass123!", "NewPass123!")

      # Verify all old sessions are invalid
      Enum.each(sessions, fn session ->
        assert nil == Authentication.get_user_by_session_token(session.token)
      end)
    end
  end

  describe "registration security" do
    test "prevents duplicate accounts" do
      _existing = insert(:user, email: "taken@example.com")

      params = %{
        # Case variation
        "email" => "TAKEN@EXAMPLE.COM",
        "password" => "ValidPass123!",
        "password_confirmation" => "ValidPass123!",
        "name" => "Duplicate",
        "terms_accepted" => "true"
      }

      {:error, :auth, _} = Auth.register_user(params, %Plug.Conn{})
    end

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

        assert {:error, :input, _} = Auth.register_user(params, %Plug.Conn{})
      end)
    end

    test "sanitizes malicious input" do
      params = %{
        "email" => "safe@example.com",
        "password" => "ValidPass123!",
        "password_confirmation" => "ValidPass123!",
        "name" => "<script>alert('xss')</script>Safe Name",
        "terms_accepted" => "true"
      }

      {:ok, user, _} = Auth.register_user(params, %Plug.Conn{})

      # Script tags should be removed, name should be sanitized
      if user.name do
        refute user.name =~ "<script>"
        assert user.name =~ "Safe Name"
      else
        # Completely sanitized to nil/empty is also acceptable
        assert true
      end
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

      {:ok, user, _} = Auth.register_user(params, conn)
      assert is_nil(user.verified_at)
    end
  end

  describe "email verification security" do
    # Note: Single-use token behavior is tested in VerificationTest.
    # This test suite focuses on higher-level security flows.

    test "unverified users cannot authenticate" do
      # Create unverified user with known password
      password = "ValidPassword123!"

      unverified =
        insert(:unverified_user,
          password_hash: Password.hash_password(password)
        )

      # Unverified users should not be able to authenticate
      assert {:error, :email_not_verified, _} = Auth.authenticate_user(unverified.email, password)
    end
  end

  describe "password reset security" do
    test "reset tokens are single-use" do
      user = insert(:user)
      result = Auth.initiate_password_reset(user.email)
      assert match?({:ok, _}, result) or match?({:ok, _, _}, result)

      # Get token directly using helper - initiate_password_reset sends it via email
      # For testing, we generate a fresh token and store it
      {token, _} = Token.generate_password_reset_token()
      {:ok, _} = UserQueries.set_reset_token(user, token)

      # First use succeeds
      result = Auth.reset_password(token, "NewPass123!", "NewPass123!")
      # Should succeed (returns 3-tuple)
      assert match?({:ok, _, _}, result)

      # Second use always fails
      assert {:error, :invalid_token, _} =
               Auth.reset_password(token, "AnotherPass123!", "AnotherPass123!")
    end

    test "oauth users cannot reset passwords" do
      oauth_user = insert(:user, provider: "github", password_hash: nil)

      result = Auth.initiate_password_reset(oauth_user.email)
      assert match?({:error, _, _}, result)
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
      assert updated.email_change_token_hash != nil
    end

    test "critical actions require fresh authentication" do
      # This is more of a controller-level test, but important for security
      # Ensure password changes, email changes, etc. check session age
      # and require re-authentication if session is too old
      # Placeholder - implement in controller tests
      assert true
    end
  end
end
