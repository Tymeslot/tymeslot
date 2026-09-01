defmodule Tymeslot.Auth.AuthenticationTest do
  use Tymeslot.DataCase, async: true

  @moduletag :auth

  alias Tymeslot.Auth.Authentication
  alias Tymeslot.Security.Password

  import Tymeslot.Factory

  describe "authenticate_user/3" do
    test "successful authentication returns {:ok, user, message}" do
      password = "ValidPass123!"
      user = insert(:user, password_hash: Password.hash_password(password))

      assert {:ok, returned_user, "Login successful."} =
               Authentication.authenticate_user(user.email, password)

      assert returned_user.id == user.id
    end

    test "successful authentication emits [:tymeslot, :auth, :login_completed] telemetry" do
      password = "ValidPass123!"
      user = insert(:user, password_hash: Password.hash_password(password))

      ref = :telemetry_test.attach_event_handlers(self(), [[:tymeslot, :auth, :login_completed]])

      assert {:ok, _user, _msg} = Authentication.authenticate_user(user.email, password)

      assert_received {[:tymeslot, :auth, :login_completed], ^ref, %{count: 1},
                       %{method: "password"}}
    end

    test "unverified user returns {:error, :email_not_verified, _}" do
      password = "ValidPass123!"
      user = insert(:unverified_user, password_hash: Password.hash_password(password))

      assert {:error, :email_not_verified, message} =
               Authentication.authenticate_user(user.email, password)

      assert message == "Please verify your email address before logging in."
    end

    test "consistent error messages prevent user enumeration" do
      # Non-existent user
      {:error, _reason, message1} =
        Authentication.authenticate_user("fake@example.com", "password")

      # Existing user wrong password
      user = insert(:user, password_hash: Password.hash_password("RealPass123!"))
      {:error, _reason, message2} = Authentication.authenticate_user(user.email, "WrongPass")

      # Messages must be identical
      assert message1 == message2
    end

    test "validates input to prevent injection attacks" do
      assert {:error, :invalid_input, _message} = Authentication.authenticate_user("", "pass")
      assert {:error, :invalid_input, _message} = Authentication.authenticate_user("email", "")
    end

    test "password over 1024 bytes is rejected before bcrypt runs" do
      # A 1025-byte password must be rejected at validation, not passed to bcrypt
      long_password = String.duplicate("A", 1025)

      assert {:error, :invalid_input, errors} =
               Authentication.authenticate_user("test@example.com", long_password)

      assert errors[:password]
    end

    test "password of 1024 multibyte characters (>1024 bytes) is rejected before bcrypt runs" do
      # 1024 × 4-byte codepoints = 4096 bytes; byte_size check must catch what String.length would miss
      long_password = String.duplicate("𠜎", 1025)

      assert {:error, :invalid_input, errors} =
               Authentication.authenticate_user("test@example.com", long_password)

      assert errors[:password]
    end

    test "nil password returns {:error, :invalid_input, _}" do
      assert {:error, :invalid_input, errors} =
               Authentication.authenticate_user("test@example.com", nil)

      assert errors[:password]
    end

    test "oauth accounts cannot use password authentication" do
      oauth_user = insert(:user, provider: "google", password_hash: nil)

      assert {:error, :oauth_user, _error_message} =
               Authentication.authenticate_user(oauth_user.email, "any-password")
    end
  end

  describe "get_user_by_session_token/1" do
    test "returns user for valid session" do
      user = insert(:user)
      session = insert(:user_session, user: user)

      assert %{id: id} = Authentication.get_user_by_session_token(session.token)
      assert id == user.id
    end

    test "expired sessions cannot authenticate" do
      user = insert(:user)

      expired =
        insert(:user_session,
          user: user,
          expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)
        )

      assert nil == Authentication.get_user_by_session_token(expired.token)
    end

    test "returns nil for nonexistent token" do
      assert nil == Authentication.get_user_by_session_token("nonexistent-token")
    end
  end
end
