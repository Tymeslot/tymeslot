defmodule Tymeslot.Auth.AdminUserQueriesTest do
  @moduledoc false

  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.Auth.AdminUserQueries

  # `any_admin_uses_password_auth?/1` backs the lockout guard in
  # `Tymeslot.AppSettings.LockoutPolicy`: it must count only admins who can
  # actually pass `Tymeslot.Auth.Authentication.verify_user_password/2`'s
  # gate, or the guard can be talked into disabling the last working sign-in
  # path by an admin who merely has a password hash on file.
  describe "any_admin_uses_password_auth?/1" do
    test "true for an admin with a verified, non-OAuth password account" do
      insert(:user, is_admin: true, password_hash: "hash", verified_at: DateTime.utc_now())

      assert AdminUserQueries.any_admin_uses_password_auth?()
    end

    test "false for an unverified admin, even with a password hash set" do
      insert(:user, is_admin: true, password_hash: "hash", verified_at: nil)

      refute AdminUserQueries.any_admin_uses_password_auth?()
    end

    test "false for an OAuth-only admin, even with a leftover password hash" do
      insert(:user,
        is_admin: true,
        password_hash: "hash",
        verified_at: DateTime.utc_now(),
        provider: "google",
        google_user_id: "google-1"
      )

      refute AdminUserQueries.any_admin_uses_password_auth?()
    end

    test "false when no admin has a password hash at all" do
      insert(:user, is_admin: true, password_hash: nil, verified_at: DateTime.utc_now())

      refute AdminUserQueries.any_admin_uses_password_auth?()
    end
  end
end
