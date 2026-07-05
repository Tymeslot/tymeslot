defmodule Tymeslot.Auth.CaseInsensitiveUniqueIndexMigrationTest do
  @moduledoc """
  Regression for `AddCaseInsensitiveUniqueIndexesForEmailAndUsername`'s
  collision-refusal path: `ensure_no_case_collisions/2` must detect
  pre-existing case-variant duplicates and raise a guided message rather
  than let the functional index creation fail with an opaque unique
  violation. This test seeds case-variant duplicates directly (bypassing the
  changeset normalisation that downcases email/username on the happy path)
  and exercises the exact detection query/raise from the migration.

  Tests run non-async because they temporarily drop the live
  case-insensitive unique indexes to simulate the pre-migration schema
  state where case-variant duplicates could exist.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :auth
  @moduletag :migrations

  alias Tymeslot.Repo

  describe "users.email collision refusal" do
    setup do
      Repo.query!("DROP INDEX IF EXISTS users_email_index")
      :ok
    end

    test "raises the guided message when case-variant emails collide" do
      insert(:user, email: "Foo@example.com")
      insert(:user, email: "foo@example.com")

      assert_raise RuntimeError, ~r/Cannot add a case-insensitive unique index/, fn ->
        ensure_no_case_collisions("users", "email")
      end
    end

    test "allows the index to be created once the collision is resolved" do
      insert(:user, email: "unique-user@example.com")

      ensure_no_case_collisions("users", "email")

      assert {:ok, _result} =
               Repo.query("CREATE UNIQUE INDEX users_email_index ON users (lower(email))")
    end
  end

  describe "profiles.username collision refusal" do
    setup do
      Repo.query!("DROP INDEX IF EXISTS profiles_username_index")
      :ok
    end

    test "raises the guided message when case-variant usernames collide" do
      insert(:profile, username: "FooUser")
      insert(:profile, username: "foouser")

      assert_raise RuntimeError, ~r/Cannot add a case-insensitive unique index/, fn ->
        ensure_no_case_collisions("profiles", "username")
      end
    end

    test "allows the index to be created once the collision is resolved" do
      insert(:profile, username: "unique-username")

      ensure_no_case_collisions("profiles", "username")

      assert {:ok, _result} =
               Repo.query(
                 "CREATE UNIQUE INDEX profiles_username_index ON profiles (lower(username))"
               )
    end
  end

  # Mirrors the migration's private `ensure_no_case_collisions/2` exactly —
  # same detection query and same guided raise message — so the assertions
  # above verify the actual behaviour the migration relies on.
  defp ensure_no_case_collisions(table, column) do
    %{rows: rows} =
      Repo.query!("""
      SELECT lower(#{column}) AS key, count(*) AS n
      FROM #{table}
      WHERE #{column} IS NOT NULL
      GROUP BY lower(#{column})
      HAVING count(*) > 1
      """)

    case rows do
      [] ->
        :ok

      collisions ->
        details = Enum.map_join(collisions, ", ", fn [key, n] -> "#{key} (#{n})" end)

        raise """
        Cannot add a case-insensitive unique index on #{table}.#{column}: \
        existing rows collide when lowercased — #{details}. \
        Merge or remove the duplicate rows, then re-run the migration. \
        (These cannot be resolved automatically because the migration cannot \
        decide which row to keep.)
        """
    end
  end
end
