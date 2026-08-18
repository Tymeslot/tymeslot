defmodule Tymeslot.Auth.CaseInsensitiveUniqueIndexMigrationTest do
  @moduledoc """
  Regression for `20260702200554_add_case_insensitive_unique_indexes_for_email_and_username`
  and its collision-refusal path: the migration must detect pre-existing
  case-variant duplicates and raise a guided message rather than let the
  functional index creation fail with an opaque unique violation.

  Every test rolls the migration back first, which restores the
  case-sensitive indexes the migration replaced. That is what makes seeding
  case-variant duplicates possible, and it means `up` runs against the schema
  it met on a real database. The migration module is loaded from `priv` and
  run through `Ecto.Migrator`; see `Tymeslot.Test.MigrationRunner`.

  Runs non-async because it rewrites live indexes for the duration of the
  test.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :auth
  @moduletag :migrations

  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_702_200_554

  setup do
    # Back to the pre-migration schema: plain, case-sensitive unique indexes,
    # under which case-variant duplicates are legal.
    MigrationRunner.down!(@version)

    :ok
  end

  describe "users.email collision refusal" do
    test "raises the guided message when case-variant emails collide" do
      insert(:user, email: "Foo@example.com")
      insert(:user, email: "foo@example.com")

      assert_raise RuntimeError, ~r/Cannot add a case-insensitive unique index/, fn ->
        MigrationRunner.up!(@version)
      end
    end

    test "creates the case-insensitive index when there is no collision" do
      insert(:user, email: "unique-user@example.com")

      MigrationRunner.up!(@version)

      assert index_definition("users_email_index") =~ "lower((email)::text)"
    end
  end

  describe "profiles.username collision refusal" do
    test "raises the guided message when case-variant usernames collide" do
      insert(:profile, username: "FooUser")
      insert(:profile, username: "foouser")

      assert_raise RuntimeError, ~r/Cannot add a case-insensitive unique index/, fn ->
        MigrationRunner.up!(@version)
      end
    end

    test "creates the case-insensitive index when there is no collision" do
      insert(:profile, username: "unique-username")

      MigrationRunner.up!(@version)

      assert index_definition("profiles_username_index") =~ "lower((username)::text)"
    end
  end

  describe "the installed indexes" do
    test "reject case-variant duplicates once the migration has run" do
      insert(:user, email: "casefold@example.com")

      MigrationRunner.up!(@version)

      assert_raise Ecto.ConstraintError, ~r/users_email_index/, fn ->
        insert(:user, email: "CaseFold@example.com")
      end
    end
  end

  defp index_definition(name) do
    %{rows: [[definition]]} =
      Repo.query!("SELECT indexdef FROM pg_indexes WHERE indexname = $1", [name])

    definition
  end
end
