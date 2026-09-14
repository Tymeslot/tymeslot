defmodule Tymeslot.Migrations.RebuildProviderEventIdIndexTest do
  @moduledoc """
  Covers `20260911153135_rebuild_provider_event_id_index_if_invalid`, whose
  whole point is that it drops before it creates.

  The migration it heals (`20260910134458`) builds its index with
  `create_if_not_exists ... concurrently: true`. An interrupted concurrent
  build leaves the index behind marked `indisvalid = false`, and on the next
  boot `IF NOT EXISTS` sees the name, skips the create, and records the
  version, so the useless index survives every future migration run. The first
  test below reproduces exactly that starting state and asserts the migration
  gets out of it; run it against the old `create_if_not_exists` form and it
  fails, because the index comes back still invalid.

  Outside the sandbox, necessarily: the migration disables the DDL transaction
  so its `CREATE INDEX CONCURRENTLY` can run at all, which a sandboxed test's
  wrapping transaction would forbid. The migration is replayed rather than
  re-run from scratch, and it restores its own version row, so the database is
  left exactly as it was found.

  Tagged `:migrations`, which is excluded from every default run: this rebuilds
  a live index on a shared table. Run it with `mix test --only migrations`.
  """

  use ExUnit.Case, async: false

  @moduletag :migrations
  @moduletag :database

  alias Ecto.Adapters.SQL.Sandbox
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_911_153_135

  @index "provider_calendar_events_integration_provider_event_id_index"

  setup do
    check_out!()

    on_exit(fn ->
      # A fresh process: the connection this test held was checked back in when
      # it exited. Leave the index behind healthy whatever the test (or a
      # failing assertion part-way through one) did to it.
      check_out!()

      unless index_exists?() and index_valid?() do
        Repo.query!("DROP INDEX IF EXISTS #{@index}")

        Repo.query!(
          "CREATE INDEX #{@index} ON provider_calendar_events " <>
            "(calendar_integration_id, provider_event_id)"
        )
      end
    end)

    :ok
  end

  test "rebuilds an index an interrupted concurrent build left invalid" do
    mark_invalid!()
    refute index_valid?()

    MigrationRunner.rerun!(@version)

    assert index_valid?()
  end

  test "recreates the index when it is missing entirely" do
    Repo.query!("DROP INDEX #{@index}")
    refute index_exists?()

    MigrationRunner.rerun!(@version)

    assert index_valid?()
  end

  test "rebuilds it with the shape the query it serves needs" do
    MigrationRunner.rerun!(@version)

    assert %{rows: [[definition]]} =
             Repo.query!("SELECT indexdef FROM pg_indexes WHERE indexname = $1", [@index])

    # Not unique, deliberately: an expanded occurrence of a recurring series
    # carries its parent's provider_event_id. Both columns, in this order, or
    # the bitmap OR in ProviderCalendarEventQueries.get_by_identifiers/2 cannot
    # use it.
    refute definition =~ "UNIQUE"
    assert definition =~ "(calendar_integration_id, provider_event_id)"

    # 60 bytes, under PostgreSQL's 63-byte identifier limit; the generated name
    # would be 72 and silently truncated, which is why it is set explicitly.
    assert byte_size(@index) <= 63
  end

  # The state an interrupted `CREATE INDEX CONCURRENTLY` leaves behind. Writing
  # the catalogue directly is the only way to reach it for a non-unique index:
  # there is no data that can make this particular build fail.
  defp mark_invalid! do
    Repo.query!(
      "UPDATE pg_index SET indisvalid = false " <>
        "WHERE indexrelid = (SELECT oid FROM pg_class WHERE relname = $1)",
      [@index]
    )
  end

  defp index_valid? do
    %{rows: [[valid]]} =
      Repo.query!(
        "SELECT pgi.indisvalid FROM pg_index AS pgi " <>
          "JOIN pg_class AS c ON c.oid = pgi.indexrelid WHERE c.relname = $1",
        [@index]
      )

    valid
  end

  defp index_exists? do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM pg_indexes WHERE indexname = $1", [@index])

    count > 0
  end

  defp check_out! do
    case Sandbox.checkout(Repo, sandbox: false) do
      :ok -> :ok
      {:already, :owner} -> :ok
    end
  end
end
