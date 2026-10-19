defmodule Tymeslot.ReleaseTest do
  use Tymeslot.DataCase, async: false

  @moduletag :auth

  import Tymeslot.AppSettingsEnvHelpers, only: [pin_setting: 2, restore_app_settings_env: 1]

  alias Tymeslot.AppSettings
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Release
  alias Tymeslot.Repo

  import Tymeslot.Factory
  import Tymeslot.AppSettingsEnvHelpers

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

  describe "demote_admin/2" do
    test "demotes an existing admin when another admin remains" do
      admin = insert(:user, is_admin: true)
      _other_admin = insert(:user, is_admin: true)

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

    test "refuses to demote the only remaining admin without force" do
      admin = insert(:user, is_admin: true)

      assert {:error, :last_admin} = Release.demote_admin(admin.email)
      assert Repo.reload!(admin).is_admin
    end

    test "refuses when the only other admin signs in with a password and password sign-in is off" do
      restore_app_settings_env(%{})
      enable_credentialed_oauth()
      Application.put_env(:tymeslot, :password_auth_enabled, false)

      admin =
        insert(:user,
          is_admin: true,
          provider: "oauth",
          provider_uid: "oidc-uid-1",
          password_hash: nil
        )

      _password_admin = insert(:user, is_admin: true)

      assert {:error, :last_admin} = Release.demote_admin(admin.email)
      assert Repo.reload!(admin).is_admin
    end

    test "demotes the only remaining admin when forced" do
      admin = insert(:user, is_admin: true)

      assert {:ok, updated} = Release.demote_admin(admin.email, true)
      refute updated.is_admin
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

  describe "reopen_registration/0" do
    setup :restore_app_settings_env

    test "opens registration when the admin setting has closed it" do
      assert {:ok, _settings} = AppSettings.update(%{registration_enabled: false})
      refute Config.registration_enabled?()

      assert {:ok, _settings} = Release.reopen_registration()

      assert Config.registration_enabled?()
      assert AppSettings.get!().registration_enabled == true
    end

    test "refuses to run when admin UI is disabled" do
      assert {:ok, _settings} = AppSettings.update(%{registration_enabled: false})
      Application.put_env(:tymeslot, :enable_admin_ui, false)

      assert {:error, :admin_ui_disabled} = Release.reopen_registration()
      refute Config.registration_enabled?()
    end

    test "points at the variable when REGISTRATION_ENABLED fixes registration" do
      Application.put_env(:tymeslot, :registration_enabled, false)
      pin_setting(:registration_enabled, "REGISTRATION_ENABLED")

      assert {:error, {:pinned, :registration_enabled, "REGISTRATION_ENABLED"}} =
               Release.reopen_registration()

      refute Config.registration_enabled?()
      assert AppSettings.get!().registration_enabled == nil
    end
  end
end
