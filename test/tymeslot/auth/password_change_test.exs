defmodule Tymeslot.Auth.PasswordChangeTest do
  use Tymeslot.DataCase, async: true

  @moduletag :auth

  alias Tymeslot.Auth
  alias Tymeslot.Auth.UserSessionSchema
  alias Tymeslot.Security.Password

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
      assert {:error, "Current password is incorrect"} =
               Auth.update_user_password(user, "WrongPass123!", "NewPass456!", "NewPass456!")
    end

    test "fails when new password is the same as the current password", %{user: user} do
      assert {:error, message} =
               Auth.update_user_password(
                 user,
                 "CurrentPass123!",
                 "CurrentPass123!",
                 "CurrentPass123!"
               )

      assert message =~ "different from current"
    end

    test "fails when new password and confirmation do not match", %{user: user} do
      assert {:error, message} =
               Auth.update_user_password(
                 user,
                 "CurrentPass123!",
                 "NewPass456!",
                 "DifferentPass456!"
               )

      assert message =~ "match"
    end

    test "fails when new password is too short", %{user: user} do
      assert {:error, message} =
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
      TymeslotWeb.Endpoint.subscribe("users_sessions:#{Base.url_encode64(session.token)}")

      assert {:ok, _updated_user} =
               Auth.update_user_password(user, "CurrentPass123!", "NewPass456!", "NewPass456!")

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end
  end
end
