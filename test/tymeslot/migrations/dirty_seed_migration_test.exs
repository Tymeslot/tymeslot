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
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator

  @seed_path Path.expand("../../support/migration_dirty_seed.sql", __DIR__)
  @migrations_to_test 5

  # PostgreSQL refuses to drop a database that still has a session attached,
  # and the running application holds a dozen: `Tymeslot.Repo`'s pool, plus the
  # separate connection Oban's Postgres notifier keeps open. The pool is
  # stopped and restarted around each individual drop (see `reset_database!/0`)
  # because the migrator needs it in between, but Oban cannot come back that
  # early: it refuses to boot against a database whose `oban_jobs` table does
  # not exist yet. So it stays down for the whole test and returns once the
  # final migration run has rebuilt the schema.
  setup do
    :ok = Supervisor.terminate_child(Tymeslot.Supervisor, Oban)

    on_exit(fn ->
      # Rebuilding the schema ran a full migration pass over the live pool, so
      # its connections carry prepared-statement plans built against a
      # half-migrated database. PostgreSQL rejects such a plan the moment later
      # DDL changes the result type ("cached plan must not change result
      # type"), which is a failure the *next* migration test would inherit.
      # Recycling the pool one last time hands it on with an empty cache.
      restart_repo!()
      {:ok, _oban} = Supervisor.restart_child(Tymeslot.Supervisor, Oban)

      # `test_helper.exs` puts the sandbox in manual mode once, at boot.
      # Restarting the repo resets the pool to its default mode, so put it back
      # before the next test module tries to check a connection out.
      Sandbox.mode(Tymeslot.Repo, :manual)
    end)

    :ok
  end

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

          # Seed adversarial data. The seed file is a script of many statements,
          # which the extended query protocol rejects ("cannot insert multiple
          # commands into a prepared statement"), so send it over the simple
          # protocol instead.
          seed_sql = File.read!(@seed_path)
          SQL.query!(Tymeslot.Repo, seed_sql, [], query_type: :text)

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

  # Restarting the pool is not just what frees the database for the drop; it is
  # also what keeps the drop safe for the rest of the suite, because the new
  # pool connects to the freshly created database rather than carrying dead
  # sockets forward.
  defp reset_database! do
    :ok = Supervisor.terminate_child(Tymeslot.Supervisor, Tymeslot.Repo)

    try do
      Mix.Task.rerun("ecto.drop", ["-r", "Tymeslot.Repo", "--quiet"])
      Mix.Task.rerun("ecto.create", ["-r", "Tymeslot.Repo", "--quiet"])
    after
      {:ok, _repo} = Supervisor.restart_child(Tymeslot.Supervisor, Tymeslot.Repo)
    end
  end

  defp restart_repo! do
    :ok = Supervisor.terminate_child(Tymeslot.Supervisor, Tymeslot.Repo)
    {:ok, _repo} = Supervisor.restart_child(Tymeslot.Supervisor, Tymeslot.Repo)
  end

  defp migrations_path do
    "priv/repo/migrations"
  end
end
