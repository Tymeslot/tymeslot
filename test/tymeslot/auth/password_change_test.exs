defmodule Tymeslot.Auth.PasswordChangeTest do
  use Tymeslot.DataCase, async: true

  @moduletag :auth

  alias Tymeslot.Auth
  alias Tymeslot.Auth.{PasswordReset, UserSchema, UserSessionSchema, UserTokenQueries}
  alias Tymeslot.Security.{Password, Token}
  alias TymeslotWeb.Endpoint

  import Tymeslot.Factory

  describe "update_user_password/4" do
    setup do
      user = insert(:user, password_hash: Password.hash_password("CurrentPass123!"))
      {:ok, user: user}
    end

    test "successfully updates password hash in the database", %{user: user} do
      assert {:ok, updated_user} =
               Auth.update_user_password(user, "CurrentPass123!", "NewPass456!", "NewPass456!")

      assert Password.verify_password("NewPass456!", updated_user.password_hash)
      refute Password.verify_password("CurrentPass123!", updated_user.password_hash)
    end

    test "fails with wrong current password", %{user: user} do
      assert {:error, %{current_password: "Current password is incorrect"}} =
               Auth.update_user_password(user, "WrongPass123!", "NewPass456!", "NewPass456!")
    end

    test "reports a wrong current password even when the new password equals it", %{user: user} do
      assert {:error, %{current_password: "Current password is incorrect"}} =
               Auth.update_user_password(user, "WrongPass123!", "WrongPass123!", "WrongPass123!")
    end

    test "fails when new password is the same as the current password", %{user: user} do
      assert {:error, %{new_password: message}} =
               Auth.update_user_password(
                 user,
                 "CurrentPass123!",
                 "CurrentPass123!",
                 "CurrentPass123!"
               )

      assert message =~ "different from current"
    end

    test "fails when new password and confirmation do not match", %{user: user} do
      assert {:error, %{new_password_confirmation: message}} =
               Auth.update_user_password(
                 user,
                 "CurrentPass123!",
                 "NewPass456!",
                 "DifferentPass456!"
               )

      assert message =~ "match"
    end

    test "fails when new password is too short", %{user: user} do
      assert {:error, %{new_password: message}} =
               Auth.update_user_password(user, "CurrentPass123!", "short", "short")

      assert message =~ "8 characters"
    end

    test "invalidates all existing sessions on successful password change", %{user: user} do
      session = insert(:user_session, user: user)

      assert {:ok, _updated_user} =
               Auth.update_user_password(user, "CurrentPass123!", "NewPass456!", "NewPass456!")

      refute Repo.get(UserSessionSchema, session.id)
    end

    test "disconnects live sockets of revoked sessions", %{user: user} do
      session = insert(:user_session, user: user)
      Endpoint.subscribe("users_sessions:#{Base.url_encode64(Token.hash_token(session.token))}")

      assert {:ok, _updated_user} =
               Auth.update_user_password(user, "CurrentPass123!", "NewPass456!", "NewPass456!")

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "revokes a pending email change and a live reset link", %{user: user} do
      change_token = Token.generate_token()

      {:ok, user} =
        UserTokenQueries.request_email_change(user, "pending@example.com", change_token)

      reset_token = Token.generate_token()
      {:ok, user} = UserTokenQueries.set_reset_token(user, reset_token)

      assert {:ok, updated_user} =
               Auth.update_user_password(user, "CurrentPass123!", "NewPass456!", "NewPass456!")

      assert updated_user.pending_email == nil
      assert updated_user.email_change_token_hash == nil
      assert updated_user.reset_token_hash == nil

      assert {:error, {:invalid_token, _message}} = Auth.verify_email_change(change_token)
      assert {:error, :invalid_token, _message} = PasswordReset.verify_token(reset_token)
    end

    # The account page passes the user it loaded at mount. Someone who knew
    # the old password requests an email change to their own address after
    # that; the owner's password change must still kill it, although the
    # struct it was handed shows no pending change and no reset token.
    test "revokes tokens issued after the caller loaded its copy of the user", %{user: stale_user} do
      change_token = Token.generate_token()

      {:ok, _fresh} =
        UserTokenQueries.request_email_change(stale_user, "attacker@example.com", change_token)

      reset_token = Token.generate_token()
      {:ok, _fresh} = UserTokenQueries.set_reset_token(stale_user, reset_token)

      assert stale_user.pending_email == nil
      assert stale_user.reset_token_hash == nil

      assert {:ok, _updated_user} =
               Auth.update_user_password(
                 stale_user,
                 "CurrentPass123!",
                 "NewPass456!",
                 "NewPass456!"
               )

      stored = Repo.get!(UserSchema, stale_user.id)
      assert stored.pending_email == nil
      assert stored.email_change_token_hash == nil
      assert stored.reset_token_hash == nil

      assert {:error, {:invalid_token, _message}} = Auth.verify_email_change(change_token)
      assert {:error, :invalid_token, _message} = PasswordReset.verify_token(reset_token)
      assert Repo.get!(UserSchema, stale_user.id).email == stale_user.email
    end

    test "checks the current password against the stored hash, not the caller's copy", %{
      user: stale_user
    } do
      {:ok, _user} =
        Auth.update_user_password(stale_user, "CurrentPass123!", "NewPass456!", "NewPass456!")

      # The stale struct still carries the old hash; the old password must not pass.
      assert {:error, %{current_password: "Current password is incorrect"}} =
               Auth.update_user_password(stale_user, "CurrentPass123!", "Other789!", "Other789!")
    end

    test "reports every malformed field at once", %{user: user} do
      assert {:error, errors} = Auth.update_user_password(user, "", "short", "different")

      assert errors.current_password == "Password is required"
      assert errors.new_password =~ "8 characters"
      assert Map.has_key?(errors, :new_password_confirmation)
    end

    test "returns the user without the plaintext password", %{user: user} do
      assert {:ok, updated_user} =
               Auth.update_user_password(user, "CurrentPass123!", "NewPass456!", "NewPass456!")

      assert updated_user.password == nil
      assert updated_user.password_confirmation == nil
    end

    test "checks the current password as login does, not against the creation policy" do
      # Set under an older, weaker policy: no uppercase letter, no symbol.
      user = insert(:user, password_hash: Password.hash_password("legacypassword1"))

      assert {:ok, _updated_user} =
               Auth.update_user_password(user, "legacypassword1", "NewPass456!", "NewPass456!")
    end

    test "reports a missing current password on its field", %{user: user} do
      assert {:error, %{current_password: "Password is required"}} =
               Auth.update_user_password(user, "", "NewPass456!", "NewPass456!")

      assert {:error, %{current_password: "Password is required"}} =
               Auth.update_user_password(user, nil, "NewPass456!", "NewPass456!")
    end

    test "rejects an oversized current password without hashing it", %{user: user} do
      assert {:error, %{current_password: "Current password is incorrect"}} =
               Auth.update_user_password(
                 user,
                 String.duplicate("a", 1025),
                 "NewPass456!",
                 "NewPass456!"
               )
    end

    test "returns an error, not a crash, for an account with no password" do
      user = insert(:user, provider: "google", password_hash: nil)

      assert {:error, %{current_password: "Current password is incorrect"}} =
               Auth.update_user_password(user, "Anything123!", "NewPass456!", "NewPass456!")
    end

    test "applies the shared password policy to the new password", %{user: user} do
      # Long enough, but missing the special character the policy requires.
      assert {:error, %{new_password: "Password must contain at least one special character"}} =
               Auth.update_user_password(user, "CurrentPass123!", "NewPass4567", "NewPass4567")
    end
  end
end
