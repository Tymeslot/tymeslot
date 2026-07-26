defmodule Tymeslot.Migrations.DirtySeedMigrationTest do
  @moduledoc """
  Runs the latest migrations against a database pre-seeded with adversarial
  data. Catches constraint violations, failed backfills, and data assumptions
  that don't hold for real-world installations.

  This test is intentionally slow and non-async — it manipulates the real
  database schema outside the sandbox.
  """

  use ExUnit.Case, async: false

  @moduletag :migrations
  @moduletag :database

  alias Ecto.Adapters.SQL
  alias Ecto.Migrator

  @seed_path Path.expand("../../support/migration_dirty_seed.sql", __DIR__)
  @migrations_to_test 5

  describe "migrations against dirty seed data" do
    test "latest #{@migrations_to_test} migrations succeed with adversarial data" do
      all_migrations = all_migration_versions()

      if length(all_migrations) < @migrations_to_test do
        :ok
      else
        target_versions = Enum.take(all_migrations, -@migrations_to_test)
        migrate_to = hd(target_versions) - 1

        try do
          # Reset DB and migrate up to just before our target range
          reset_database!()
          Migrator.run(Tymeslot.Repo, migrations_path(), :up, to: migrate_to)

          # Seed adversarial data
          seed_sql = File.read!(@seed_path)
          SQL.query!(Tymeslot.Repo, seed_sql)

          # Run the target migrations — this is the actual test
          results = Migrator.run(Tymeslot.Repo, migrations_path(), :up, all: true)
          assert length(results) == length(target_versions)
        after
          # Always restore clean state for other tests
          reset_database!()
          Migrator.run(Tymeslot.Repo, migrations_path(), :up, all: true)
        end
      end
    end
  end

  defp all_migration_versions do
    migrations_path()
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      path |> Path.basename() |> String.split("_", parts: 2) |> hd() |> String.to_integer()
    end)
    |> Enum.sort()
  end

  defp reset_database! do
    Mix.Task.rerun("ecto.drop", ["-r", "Tymeslot.Repo", "--quiet"])
    Mix.Task.rerun("ecto.create", ["-r", "Tymeslot.Repo", "--quiet"])
  end

  defp migrations_path do
    "priv/repo/migrations"
  end
end
