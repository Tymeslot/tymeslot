defmodule Tymeslot.ReleaseTest do
  use Tymeslot.DataCase, async: false

  @moduletag :auth

  alias Tymeslot.Release
  alias Tymeslot.Repo

  import Tymeslot.Factory

  setup do
    # A downstream overlay's config can set enable_admin_ui to false. Force it
    # back to true for the Release helper happy paths.
    Application.put_env(:tymeslot, :enable_admin_ui, true)
    on_exit(fn -> Application.put_env(:tymeslot, :enable_admin_ui, true) end)
    :ok
  end

  describe "promote_admin/1" do
    test "promotes the user with the given email" do
      user = insert(:user, is_admin: false)

      assert {:ok, updated} = Release.promote_admin(user.email)
      assert updated.is_admin
    end

    test "returns :not_found when no user matches the email" do
      assert {:error, :not_found} = Release.promote_admin("missing@example.com")
    end

    test "refuses to run when admin UI is disabled" do
      Application.put_env(:tymeslot, :enable_admin_ui, false)
      user = insert(:user, is_admin: false)

      assert {:error, :admin_ui_disabled} = Release.promote_admin(user.email)
      refute Repo.reload!(user).is_admin
    end
  end

  describe "demote_admin/1" do
    test "demotes an existing admin" do
      admin = insert(:user, is_admin: true)

      assert {:ok, updated} = Release.demote_admin(admin.email)
      refute updated.is_admin
    end

    test "is idempotent against a non-admin user" do
      user = insert(:user, is_admin: false)

      assert {:ok, updated} = Release.demote_admin(user.email)
      refute updated.is_admin
    end

    test "refuses to run when admin UI is disabled" do
      Application.put_env(:tymeslot, :enable_admin_ui, false)
      admin = insert(:user, is_admin: true)

      assert {:error, :admin_ui_disabled} = Release.demote_admin(admin.email)
      assert Repo.reload!(admin).is_admin
    end
  end

  describe "list_admins/0" do
    test "returns only admin users, with id + email" do
      _regular = insert(:user, is_admin: false)
      admin = insert(:user, is_admin: true)

      assert [%{id: id, email: email}] = Release.list_admins()
      assert id == admin.id
      assert email == admin.email
    end
  end
end
