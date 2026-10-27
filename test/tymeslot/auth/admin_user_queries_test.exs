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

  describe "lock_admins/0" do
    # Two lockers taking the same rows in different orders can deadlock; in id
    # order they queue instead.
    test "locks every admin, in id order" do
      ids = for _i <- 1..3, do: insert(:user, is_admin: true).id
      _not_admin = insert(:user)

      handler = "lock-admins-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler,
        [:tymeslot, :repo, :query],
        fn _event, _m, meta, _c ->
          # Only this test's own query: the handler is global, the test async.
          if self() == parent and meta[:query] =~ "FOR UPDATE",
            do: send(parent, {:locking_query, meta[:query]})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, locked} = Repo.transaction(fn -> AdminUserQueries.lock_admins() end)

      assert Enum.map(locked, & &1.id) == Enum.sort(ids)
      assert_received {:locking_query, query}
      assert query =~ ~r/ORDER BY .*"id".* FOR UPDATE/
    end
  end
end
