defmodule Tymeslot.Migrations.DirtySeedMigrationTest do
  @moduledoc """
  Runs every migration written since the seed's pinned schema version against a
  database pre-seeded with adversarial data. Catches constraint violations,
  failed backfills, and data assumptions that don't hold for real-world
  installations.

  ## Why a pinned version rather than "the last N migrations"

  The failure this test exists to catch is a migration that succeeds on an empty
  database and fails on a populated one: a NOT NULL column added without a
  backfill, a unique index built over duplicate rows, a check constraint older
  rows violate, an `UPDATE ... FROM` that trips over an orphan. Everything else
  in the gate runs migrations against an empty database, so this is the only
  place that failure shows up.

  Seeding that data requires the seed's `INSERT`s to match the schema they are
  loaded against. Pinning the split point to a fixed version is what makes that
  possible: `migration_dirty_seed.sql` is written once against the schema as of
  `@seed_schema_version` and never has to be rewritten again, because the
  schema it is loaded against never moves. A "last N migrations" window instead
  slides the load point forward with every migration added, so each new
  constraint or table rename eventually invalidates rows that were valid when
  they were written — a red build about the seed file, not about the migration
  under test.

  Pinning also widens the range: a migration stays covered until the pin is
  deliberately moved past it, instead of ageing out after N more land. It costs
  nothing extra to run, because either way the run applies every migration.

  The residual gap is that the seed cannot populate a table or column created
  after the pin, so a migration constraining a table younger than the pin still
  meets it empty. That is the trigger for moving the pin forward: add the rows
  you need, move the pin to cover them, and repair whatever the newer schema
  rejects. `CredoChecks.MigrationConstraintSafety` is the static backstop that
  covers the gap in the meantime.

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

  # The schema version `migration_dirty_seed.sql` is written against. The
  # database is migrated to exactly this version before the seed is loaded, so
  # the seed's `INSERT`s only ever have to satisfy the schema as it stood here.
  # Everything after it is what this test exercises. See the moduledoc before
  # changing it; moving it forward is a deliberate act with seed consequences,
  # never a routine response to a red build.
  @seed_schema_version 20_260_702_180_350

  # The seed file repeats the pinned version in a machine-readable header line
  # so a human reading the SQL knows which schema to write against. This test is
  # the authority; the assertion below keeps the two from drifting apart.
  @seed_version_marker ~r/^-- SEED SCHEMA VERSION:\s*(\d+)\s*$/m

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
    test "every migration after the pinned seed schema succeeds with adversarial data" do
      versions_under_test = assert_pin_is_usable!()

      try do
        # Reset the database and migrate to exactly the version the seed file
        # is written against.
        reset_database!()
        Migrator.run(Tymeslot.Repo, migrations_path(), :up, to: @seed_schema_version)

        load_seed!()
        seeded = seeded_availability!()

        # Run everything after the pin — this is the actual test.
        assert run_remaining_migrations!() == versions_under_test

        assert_availability_rekeyed!(seeded)
      after
        # Always restore clean state for other tests
        reset_database!()
        Migrator.run(Tymeslot.Repo, migrations_path(), :up, all: true)
      end
    end
  end

  # Returns the versions the seed data is exercising, and fails loudly rather
  # than silently passing if the pin no longer refers to a real migration or has
  # nothing left after it.
  defp assert_pin_is_usable! do
    all_versions = all_migration_versions()
    {before_seed, after_seed} = Enum.split_while(all_versions, &(&1 <= @seed_schema_version))

    assert @seed_schema_version in before_seed, """
    @seed_schema_version #{@seed_schema_version} is not a migration in #{migrations_path()}.

    The pin must name a real migration, because the database is migrated to
    exactly that version before test/support/migration_dirty_seed.sql is loaded.
    If that migration was squashed or removed, repoint the pin at the migration
    that now leaves the schema in the shape the seed file expects.
    """

    assert after_seed != [], """
    @seed_schema_version #{@seed_schema_version} is the newest migration, so this
    test would exercise nothing. Leave the pin where it is; it only moves when
    the seed file needs a table or column that did not exist at the pin.
    """

    assert_seed_declares_pin!()

    after_seed
  end

  defp assert_seed_declares_pin! do
    declared =
      case Regex.run(@seed_version_marker, File.read!(@seed_path)) do
        [_line, version] -> String.to_integer(version)
        nil -> nil
      end

    assert declared == @seed_schema_version, """
    test/support/migration_dirty_seed.sql declares schema version #{inspect(declared)},
    but @seed_schema_version here is #{@seed_schema_version}.

    The seed file's header line is documentation for whoever edits the SQL; this
    module is the authority. Update the `-- SEED SCHEMA VERSION:` line to match.
    """
  end

  # The seed is a script of many statements, which the extended query protocol
  # rejects ("cannot insert multiple commands into a prepared statement"), so it
  # goes over the simple protocol instead. It also has to travel as a single
  # query: the payment_transactions block toggles `session_replication_role`,
  # which is per-connection state, so splitting the script would let the pool
  # hand those statements to different connections.
  defp load_seed! do
    case SQL.query(Tymeslot.Repo, File.read!(@seed_path), [], query_type: :text) do
      {:ok, _result} ->
        :ok

      {:error, error} ->
        flunk("""
        The dirty seed failed to load against schema version #{@seed_schema_version}.

        This is a failure of the seed file, not of any migration under test: the
        statements never ran far enough to reach one. The schema the seed is
        loaded against is pinned, so the usual causes are a new row written
        against today's schema instead of the pinned one, or @seed_schema_version
        having been moved forward past a row that the newer schema rejects.

        Fix the SQL, or revert the pin — do not delete rows to make it pass
        without checking what they covered. See the maintenance rules at the top
        of test/support/migration_dirty_seed.sql.

        #{Exception.message(error)}
        """)
    end
  end

  # The availability rows as the seed left them, keyed by profile: this is the
  # "before" half of the only assertion in the suite that can prove the schedule
  # rekey preserved data, because it is the only place the rekey ever meets a
  # populated table.
  defp seeded_availability! do
    census = %{
      weekly: count_by_profile!("weekly_availability"),
      overrides: count_by_profile!("availability_overrides"),
      breaks: scalar!("SELECT COUNT(*) FROM availability_breaks")
    }

    # Without this the comparison after the migration could hold two empty
    # results against each other and pass having proved nothing — the exact
    # weakness that made an empty database useless for testing the rekey.
    assert map_size(census.weekly) > 1 and map_size(census.overrides) > 1 and
             census.breaks > 0,
           """
           The dirty seed left no availability rows across at least two profiles,
           so the schedule rekey assertions would compare empty against empty.

           Restore the WEEKLY AVAILABILITY, BREAKS AND OVERRIDES section of
           test/support/migration_dirty_seed.sql rather than relaxing this check.

           #{inspect(census)}
           """

    census
  end

  defp assert_availability_rekeyed!(seeded) do
    # Every profile gained exactly one default schedule carrying the policy it
    # used to hold on the profile itself, NULLs included (COALESCEd to the
    # column defaults) — the values a self-hoster's booking rules survive as.
    assert scalar!("SELECT COUNT(*) FROM availability_schedules WHERE is_default") ==
             scalar!("SELECT COUNT(*) FROM profiles")

    # Re-counted per schedule rather than in total, so the rekey cannot pass by
    # collapsing every profile's rows onto one schedule.
    assert count_by_default_schedule!("weekly_availability") == seeded.weekly
    assert count_by_default_schedule!("availability_overrides") == seeded.overrides

    # Breaks are reached only through their weekly row's id, so an unchanged
    # count proves the rekey updated those rows rather than replacing them.
    assert scalar!("SELECT COUNT(*) FROM availability_breaks") == seeded.breaks
  end

  defp count_by_profile!(table) do
    rows!("SELECT profile_id, COUNT(*) FROM #{table} GROUP BY profile_id")
  end

  # Joins back to the owning profile so the result is comparable with the
  # profile-keyed counts taken before the rekey dropped the column.
  defp count_by_default_schedule!(table) do
    rows!("""
    SELECT s.profile_id, COUNT(*)
    FROM #{table} AS t
    JOIN availability_schedules AS s ON s.id = t.schedule_id AND s.is_default
    GROUP BY s.profile_id
    """)
  end

  defp rows!(sql) do
    %{rows: rows} = SQL.query!(Tymeslot.Repo, sql, [])
    Map.new(rows, fn [key, count] -> {key, count} end)
  end

  defp scalar!(sql) do
    %{rows: [[value]]} = SQL.query!(Tymeslot.Repo, sql, [])
    value
  end

  defp run_remaining_migrations! do
    Migrator.run(Tymeslot.Repo, migrations_path(), :up, all: true)
  rescue
    error ->
      reraise """
              A migration after #{@seed_schema_version} failed against the dirty seed data.

              This is what the test is for: the migration works on an empty
              database and does not work on a populated one. Give it a backfill,
              a deduplication step, or a default — do not remove the seed rows
              that caught it.

              #{Exception.message(error)}
              """,
              __STACKTRACE__
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
