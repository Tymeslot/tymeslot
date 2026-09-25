defmodule Tymeslot.Auth.AdminRolesTest do
  @moduledoc """
  Who may change admin roles. The admin UI's hook is not the only guard: the
  domain refuses any actor that is not a current admin or the CLI.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :auth

  import Tymeslot.Factory

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

  describe "demote/2" do
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
end
