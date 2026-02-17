defmodule Tymeslot.Auth.AuthenticationTest do
  use Tymeslot.DataCase, async: false

  @moduletag :auth

  alias Tymeslot.Auth.Authentication
  alias Tymeslot.Security.Password

  import Tymeslot.Factory

  describe "authentication security" do
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
  end

  describe "session token authentication" do
    test "expired sessions cannot authenticate" do
      user = insert(:user)

      expired =
        insert(:user_session,
          user: user,
          expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)
        )

      assert nil == Authentication.get_user_by_session_token(expired.token)
    end
  end

  describe "oauth security" do
    test "oauth accounts cannot use password authentication" do
      oauth_user = insert(:user, provider: "google", password_hash: nil)

      # OAuth users should get an error tuple, not an exception
      assert {:error, :oauth_user, _error_message} =
               Authentication.authenticate_user(oauth_user.email, "any-password")
    end
  end
end
