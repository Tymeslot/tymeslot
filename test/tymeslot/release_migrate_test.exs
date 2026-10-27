defmodule Tymeslot.ReleaseMigrateTest do
  use Tymeslot.DataCase, async: false

  @moduletag :infrastructure

  alias Ecto.Adapters.SQL
  alias Ecto.Migrator
  alias Tymeslot.Release

  # An idempotent data migration, safe to apply again.
  @version 20_261_010_104_132

  test "migrate/1 applies a pending migration of the app's repos, and leaves nothing pending" do
    SQL.query!(Repo, "DELETE FROM schema_migrations WHERE version = $1", [@version])
    refute applied?(@version)

    # The sandbox owns one connection, so the migration lock cannot be taken
    # here (see `Tymeslot.Test.MigrationRunner`).
    assert Release.migrate(:tymeslot, migration_lock: false) == :ok

    assert applied?(@version)

    assert Enum.all?(Migrator.migrations(Repo), fn {status, _version, _name} ->
             status == :up
           end)
  end

  test "the node-bound helpers refuse when the application is not running" do
    assert_raise RuntimeError, ~r/use `bin\/tymeslot rpc`, not `eval`/, fn ->
      Release.ensure_running!([{:kernel, ~c"", ~c""}])
    end

    assert Release.ensure_running!() == :ok
  end

  defp applied?(version),
    do:
      SQL.query!(Repo, "SELECT 1 FROM schema_migrations WHERE version = $1", [version]).num_rows ==
        1
end
