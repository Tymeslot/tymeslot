defmodule Tymeslot.Auth.AdminBootstrapTest do
  use Tymeslot.DataCase, async: true

  @moduletag :auth

  alias ExUnit.CaptureLog
  alias Tymeslot.Auth.{AdminBootstrap, UserQueries, UserSchema}

  import Tymeslot.Factory

  describe "maybe_promote_first_user/2" do
    test "promotes the user when they are the only row in the table" do
      user = insert(:user)
      refute user.is_admin

      assert {:ok, promoted} = AdminBootstrap.maybe_promote_first_user(user)
      assert promoted.is_admin

      assert UserQueries.count_admins() == 1
    end

    test "does NOT promote when other users already exist" do
      _existing = insert(:user)
      newcomer = insert(:user)

      assert {:ok, returned} = AdminBootstrap.maybe_promote_first_user(newcomer)
      refute returned.is_admin

      assert UserQueries.count_admins() == 0
    end

    test "does NOT promote when other users exist even if no admin exists" do
      # This is the upgrade-from-existing-install scenario: the table has
      # users (carried over from before the is_admin column existed) but no
      # admin yet. A random new signup must NOT be able to claim admin.
      _existing_one = insert(:user)
      _existing_two = insert(:user)
      newcomer = insert(:user)

      refute UserQueries.any_admin?()

      assert {:ok, returned} = AdminBootstrap.maybe_promote_first_user(newcomer)
      refute returned.is_admin
      refute UserQueries.any_admin?()
    end
  end

  describe "warn_if_orphaned_install/0" do
    test "logs a warning when users exist but no admin" do
      insert(:user)

      log =
        CaptureLog.capture_log(fn ->
          assert :ok = AdminBootstrap.warn_if_orphaned_install()
        end)

      assert log =~ ~r/no admin/i
    end

    test "returns :ok silently when users and admins both exist" do
      insert(:user, is_admin: true)

      log =
        CaptureLog.capture_log(fn ->
          assert :ok = AdminBootstrap.warn_if_orphaned_install()
        end)

      refute log =~ "no admin"
    end

    test "returns :ok silently when no users exist at all" do
      log =
        CaptureLog.capture_log(fn ->
          assert :ok = AdminBootstrap.warn_if_orphaned_install()
        end)

      refute log =~ "no admin"
    end
  end

  describe "is_admin field guarantees" do
    test "no public UserSchema changeset accepts :is_admin from params" do
      attrs = %{
        "email" => "attacker@example.com",
        "password" => "ValidPass123!",
        "password_confirmation" => "ValidPass123!",
        "name" => "Attacker",
        "is_admin" => true
      }

      changeset = UserSchema.registration_changeset(%UserSchema{}, attrs)

      refute Map.has_key?(changeset.changes, :is_admin)
    end

    test "admin_changeset/2 is the only path to set is_admin" do
      user = insert(:user)

      changeset = UserSchema.admin_changeset(user, true)

      assert Map.fetch(changeset.changes, :is_admin) == {:ok, true}
    end
  end
end
