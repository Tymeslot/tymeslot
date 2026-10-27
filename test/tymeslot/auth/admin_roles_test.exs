defmodule Tymeslot.Auth.AdminRolesTest do
  @moduledoc """
  Who may change admin roles. The admin UI's hook is not the only guard: the
  domain refuses any actor that is not a current admin or the CLI.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :auth

  import Tymeslot.Factory
  import Tymeslot.AppSettingsEnvHelpers

  alias Tymeslot.Auth.{AdminRoles, AdminUserQueries}
  alias Tymeslot.Repo

  describe "promote/2" do
    test "an admin can promote another user" do
      admin = insert(:user, is_admin: true)
      target = insert(:user)

      assert {:ok, promoted} = AdminRoles.promote(admin, target.id)
      assert promoted.is_admin
    end

    test "the CLI can promote a user" do
      target = insert(:user)

      assert {:ok, %{is_admin: true}} = AdminRoles.promote(:cli, target.id)
    end

    test "a non-admin actor is refused and the target is left unchanged" do
      actor = insert(:user)
      target = insert(:user)

      assert {:error, :forbidden} = AdminRoles.promote(actor, target.id)
      refute Repo.reload!(target).is_admin
    end

    test "a non-admin actor cannot promote themselves" do
      actor = insert(:user)

      assert {:error, :forbidden} = AdminRoles.promote(actor, actor.id)
      refute Repo.reload!(actor).is_admin
    end

    test "an actor struct that still says admin after being demoted is refused" do
      actor = insert(:user, is_admin: true)
      _other_admin = insert(:user, is_admin: true)
      target = insert(:user)
      {:ok, _demoted} = AdminUserQueries.set_admin(actor, false)

      assert {:error, :forbidden} = AdminRoles.promote(actor, target.id)
      refute Repo.reload!(target).is_admin
    end

    test "an actor that is neither a user nor the CLI is refused" do
      target = insert(:user)

      assert {:error, :forbidden} = AdminRoles.promote(:system, target.id)
      assert {:error, :forbidden} = AdminRoles.promote(nil, target.id)
      refute Repo.reload!(target).is_admin
    end
  end

  describe "demote/3" do
    test "an admin can demote another admin" do
      admin = insert(:user, is_admin: true)
      target = insert(:user, is_admin: true)

      assert {:ok, demoted} = AdminRoles.demote(admin, target.id)
      refute demoted.is_admin
    end

    test "a non-admin actor is refused and the target stays admin" do
      actor = insert(:user)
      target = insert(:user, is_admin: true)
      _other_admin = insert(:user, is_admin: true)

      assert {:error, :forbidden} = AdminRoles.demote(actor, target.id)
      assert Repo.reload!(target).is_admin
    end

    test "an actor struct that still says admin after being demoted is refused" do
      actor = insert(:user, is_admin: true)
      target = insert(:user, is_admin: true)
      _third_admin = insert(:user, is_admin: true)
      {:ok, _demoted} = AdminUserQueries.set_admin(actor, false)

      assert {:error, :forbidden} = AdminRoles.demote(actor, target.id)
      assert Repo.reload!(target).is_admin
    end
  end

  # The last-admin guard counts the admins who could still sign in once the
  # target is demoted, not bare `is_admin` rows: an admin row nobody can sign
  # in as does not keep the install reachable.
  describe "demote/3 last-admin guard" do
    test "an admin can demote themselves when another admin can still sign in" do
      admin = insert(:user, is_admin: true)
      _other = insert(:user, is_admin: true)

      assert {:ok, demoted} = AdminRoles.demote(admin, admin.id)
      refute demoted.is_admin
    end

    test "refuses self-demotion when the only other admin is unverified" do
      admin = insert(:user, is_admin: true)
      _other = insert(:unverified_user, is_admin: true)

      assert {:error, :last_admin} = AdminRoles.demote(admin, admin.id)
      assert Repo.reload!(admin).is_admin
    end

    test "refuses self-demotion when the only other admin signs in through a disabled provider" do
      admin = insert(:user, is_admin: true)

      _other =
        insert(:user,
          is_admin: true,
          provider: "google",
          password_hash: nil,
          google_user_id: "google-uid-1"
        )

      assert {:error, :last_admin} = AdminRoles.demote(admin, admin.id)
      assert Repo.reload!(admin).is_admin
    end

    test "refuses demoting the only admin who can sign in, by another admin" do
      actor = insert(:unverified_user, is_admin: true)
      target = insert(:user, is_admin: true)

      assert {:error, :last_admin} = AdminRoles.demote(actor, target.id)
      assert Repo.reload!(target).is_admin
    end

    test "refuses the CLI demoting the only admin who can sign in, unless forced" do
      target = insert(:user, is_admin: true)
      _other = insert(:unverified_user, is_admin: true)

      assert {:error, :last_admin} = AdminRoles.demote(:cli, target.id)
      assert Repo.reload!(target).is_admin

      assert {:ok, %{is_admin: false}} = AdminRoles.demote(:cli, target.id, force: true)
    end

    test "force is the CLI's alone: an admin passing it is still refused" do
      actor = insert(:unverified_user, is_admin: true)
      target = insert(:user, is_admin: true)

      assert {:error, :last_admin} = AdminRoles.demote(actor, target.id, force: true)
      assert Repo.reload!(target).is_admin
    end
  end

  # A verified password admin only keeps the install reachable while password
  # sign-in is switched on. These tests toggle global sign-in settings, which
  # is why this module is not async.
  describe "demote/3 last-admin guard with password sign-in disabled" do
    setup :restore_app_settings_env

    setup do
      enable_credentialed_oauth()
      Application.put_env(:tymeslot, :password_auth_enabled, false)
      :ok
    end

    test "refuses self-demotion when the only other admin signs in with a password" do
      admin =
        insert(:user,
          is_admin: true,
          provider: "oauth",
          provider_uid: "oidc-uid-1",
          password_hash: nil
        )

      _password_admin = insert(:user, is_admin: true)

      assert {:error, :last_admin} = AdminRoles.demote(admin, admin.id)
      assert Repo.reload!(admin).is_admin
    end

    test "allows self-demotion when another admin signs in through a usable provider" do
      admin = insert(:user, is_admin: true)

      _sso_admin =
        insert(:user,
          is_admin: true,
          provider: "oauth",
          provider_uid: "oidc-uid-2",
          password_hash: nil
        )

      assert {:ok, %{is_admin: false}} = AdminRoles.demote(admin, admin.id)
    end
  end
end
