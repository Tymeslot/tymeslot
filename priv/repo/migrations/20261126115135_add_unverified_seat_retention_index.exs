defmodule Tymeslot.Repo.Migrations.AddUnverifiedSeatRetentionIndex do
  @moduledoc """
  Indexes the group seats cancelled without ever being verified, for the
  retention delete (`Tymeslot.Meetings.ParticipantQueries.delete_unverified_cancelled_before/1`).

  That delete filters on a verification deadline before a cutoff, among seats
  that were cancelled, never verified and had a deadline. The sweep index
  from `20261113160147` is partial on `cancelled_at IS NULL`, so it cannot
  serve it. A partial index on `verification_deadline_at` over exactly the
  delete's rows keeps it small: it holds only the lapsed holds awaiting
  pruning, which the delete itself keeps few. The predicate matches the
  query's word for word, or the planner will not use it.

  ## Existing data

  None to repair: the index is not unique, so any rows are admitted.

  ## Locking

  Built `CONCURRENTLY`, so neither the DDL transaction nor the migration lock
  can be held. `IF NOT EXISTS` alone would skip an index an interrupted build
  left invalid and record the version anyway, so an invalid one is dropped
  first and built again; a re-run over a valid index is a no-op.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @name :meeting_participants_unverified_cancelled_deadline_index

  def up do
    if invalid?(), do: drop(retention_index())
    create_if_not_exists(retention_index())
  end

  def down do
    drop_if_exists(retention_index())
  end

  defp retention_index do
    index(:meeting_participants, [:verification_deadline_at],
      where:
        "cancelled_at IS NOT NULL AND email_verified_at IS NULL AND verification_deadline_at IS NOT NULL",
      name: @name,
      concurrently: true
    )
  end

  defp invalid? do
    %{rows: rows} =
      repo().query!(
        "SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass($1)",
        [Atom.to_string(@name)]
      )

    rows == [[false]]
  end
end
