defmodule Tymeslot.Migrations.AddUnverifiedRetentionIndexToMeetingsTest do
  @moduledoc """
  Covers `20261113163019_add_unverified_retention_index_to_meetings`, which
  builds the partial index the retention delete of never-verified bookings
  reads, and heals one an interrupted build left invalid.

  Outside the sandbox, necessarily: the migration disables the DDL transaction
  so its concurrent build can run at all. The index is put back from its
  captured definition afterwards, whatever a test did to it. Tagged
  `:migrations`, which no default run includes: run it with
  `mix test --only migrations`.
  """

  use ExUnit.Case, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :bookings

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_113_163_019
  @index "meetings_unverified_verification_deadline_index"

  setup do
    check_out!()
    original = definition()
    assert original =~ "verification_deadline_at"

    on_exit(fn ->
      check_out!()

      if definition() != original do
        Repo.query!("DROP INDEX IF EXISTS #{@index}")
        Repo.query!(original)
      end

      # A test that ran `down/0` left the version off the ledger; putting it
      # back through the migrator is a no-op against the restored index.
      Migrator.up(Repo, @version, MigrationRunner.module(@version),
        migration_lock: false,
        log: false
      )
    end)

    :ok
  end

  test "builds a partial index over the never-verified bookings" do
    MigrationRunner.rerun!(@version)

    assert definition() =~ "(verification_deadline_at)"
    assert definition() =~ "verification_deadline_at IS NOT NULL"
    assert definition() =~ "email_verified_at IS NULL"
    assert valid?()
  end

  test "a re-run over a valid index is a no-op" do
    before = index_oid()

    MigrationRunner.replay!(@version)

    assert index_oid() == before
  end

  test "an invalid index is dropped and built again" do
    Repo.query!("UPDATE pg_index SET indisvalid = false WHERE indexrelid = to_regclass($1)", [
      @index
    ])

    invalid_oid = index_oid()

    MigrationRunner.replay!(@version)

    assert valid?()
    refute index_oid() == invalid_oid
  end

  test "down drops the index" do
    MigrationRunner.down!(@version)

    assert definition() == nil
  end

  defp definition do
    case Repo.query!("SELECT indexdef FROM pg_indexes WHERE indexname = $1", [@index]) do
      %{rows: [[definition]]} -> definition
      %{rows: []} -> nil
    end
  end

  defp valid? do
    %{rows: [[valid]]} =
      Repo.query!("SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass($1)", [@index])

    valid
  end

  defp index_oid do
    %{rows: [[oid]]} = Repo.query!("SELECT to_regclass($1)::oid", [@index])
    oid
  end

  defp check_out! do
    case Sandbox.checkout(Repo, sandbox: false) do
      :ok -> :ok
      {:already, :owner} -> :ok
    end
  end
end
