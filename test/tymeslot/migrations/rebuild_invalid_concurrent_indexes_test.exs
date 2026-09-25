defmodule Tymeslot.Migrations.RebuildInvalidConcurrentIndexesTest do
  @moduledoc """
  Covers `20260916121722_rebuild_invalid_concurrent_indexes`, which rebuilds
  the concurrently-built indexes an interrupted build left invalid.

  The definitions in that migration are transcriptions of six older
  migrations, and a transcription error (a lost predicate, a dropped `UNIQUE`,
  a different name) would silently change the schema on exactly the
  installations it runs on. So the central test rebuilds every index and
  compares its definition with the one the original migrations produced.

  Outside the sandbox, necessarily: the migration disables the DDL transaction
  so its concurrent builds can run at all. Every index is put back from its
  captured definition afterwards, whatever a test did to it. Tagged
  `:migrations`, which no default run includes: run it with
  `mix test --only migrations`.
  """

  use ExUnit.Case, async: false

  @moduletag :database
  @moduletag :migrations

  alias Ecto.Adapters.SQL.Sandbox
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_916_121_722

  @indexes ~w(
    payment_transactions_host_deleted_at_index
    booking_payments_stale_pending_index
    connect_accounts_user_id_live_unique_index
    connect_accounts_stripe_account_id_live_unique_index
    idx_meetings_organizer_email_start_time
    idx_meetings_attendee_email_start_time
    idx_meetings_reminders_due
    meetings_organizer_utm_source_index
    idx_oban_jobs_monitoring
    idx_oban_jobs_scheduled_monitoring
    idx_oban_jobs_args_gin
  )

  @duplicate_account "acct_rebuild_invalid_indexes_test"

  setup do
    check_out!()
    definitions = Map.new(@indexes, &{&1, definition(&1)})

    on_exit(fn ->
      check_out!()

      Repo.query!("DELETE FROM connect_accounts WHERE stripe_account_id = $1", [
        @duplicate_account
      ])

      for {index, original} <- definitions,
          not (index_valid?(index) and definition(index) == original) do
        Repo.query!("DROP INDEX IF EXISTS #{index}")
        Repo.query!(original)
      end
    end)

    %{definitions: definitions}
  end

  test "rebuilds every invalid index exactly as its original migration defined it", %{
    definitions: definitions
  } do
    Enum.each(@indexes, &mark_invalid!/1)

    MigrationRunner.rerun!(@version)

    assert Enum.reject(@indexes, &index_valid?/1) == []
    assert Map.new(@indexes, &{&1, definition(&1)}) == definitions
  end

  # An unguarded rebuild would cost every installation a full concurrent
  # rebuild at upgrade time, the `oban_jobs` GIN index included. A rebuilt
  # index gets a new OID; a skipped one keeps its own.
  test "leaves healthy indexes untouched" do
    before = Map.new(@indexes, &{&1, index_oid(&1)})

    MigrationRunner.rerun!(@version)

    assert Map.new(@indexes, &{&1, index_oid(&1)}) == before
  end

  test "does not recreate an index that is missing" do
    Repo.query!("DROP INDEX payment_transactions_host_deleted_at_index")

    MigrationRunner.rerun!(@version)

    assert definition("payment_transactions_host_deleted_at_index") == nil
  end

  # Building a unique index over rows that violate it fails, and a failed
  # migration stops the release booting. Leaving it invalid costs a slow query.
  test "leaves an invalid unique index alone when its table holds duplicates" do
    index = "connect_accounts_stripe_account_id_live_unique_index"

    # The state a unique build that failed on duplicates leaves behind: an
    # index of that name which enforces nothing, over rows that violate it.
    Repo.query!("DROP INDEX #{index}")
    Repo.query!("CREATE INDEX #{index} ON connect_accounts (stripe_account_id)")
    mark_invalid!(index)

    for _copy <- 1..2 do
      Repo.query!(
        "INSERT INTO connect_accounts (id, stripe_account_id, inserted_at, updated_at) " <>
          "VALUES (gen_random_uuid(), $1, NOW(), NOW())",
        [@duplicate_account]
      )
    end

    before = index_oid(index)

    MigrationRunner.rerun!(@version)

    assert index_oid(index) == before
    refute index_valid?(index)
  end

  # The state an interrupted `CREATE INDEX CONCURRENTLY` leaves behind.
  defp mark_invalid!(index) do
    Repo.query!("UPDATE pg_index SET indisvalid = false WHERE indexrelid = to_regclass($1)", [
      index
    ])
  end

  defp index_valid?(index) do
    case Repo.query!("SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass($1)", [
           index
         ]) do
      %{rows: [[valid]]} -> valid
      %{rows: []} -> false
    end
  end

  defp definition(index) do
    case Repo.query!("SELECT indexdef FROM pg_indexes WHERE indexname = $1", [index]) do
      %{rows: [[definition]]} -> definition
      %{rows: []} -> nil
    end
  end

  defp index_oid(index) do
    %{rows: [[oid]]} = Repo.query!("SELECT to_regclass($1)::oid", [index])
    oid
  end

  defp check_out! do
    case Sandbox.checkout(Repo, sandbox: false) do
      :ok -> :ok
      {:already, :owner} -> :ok
    end
  end
end
