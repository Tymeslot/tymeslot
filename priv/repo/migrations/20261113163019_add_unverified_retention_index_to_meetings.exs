defmodule Tymeslot.Repo.Migrations.AddUnverifiedRetentionIndexToMeetings do
  @moduledoc """
  Indexes the bookings that never left the email verification gate, for the
  retention delete (`Tymeslot.Meetings.MeetingQueries.delete_unverified_lapsed_before/1`).

  That delete filters on a verification deadline before a cutoff, among rows
  that have a deadline and were never verified. A partial index on
  `verification_deadline_at` over exactly those rows keeps it small: a
  booking that never met the gate has no deadline, and one verified has
  `email_verified_at`, so the index holds only the unverified holds and their
  released remains, which the delete itself keeps few.

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

  @name :meetings_unverified_verification_deadline_index

  def up do
    if invalid?(), do: drop(retention_index())
    create_if_not_exists(retention_index())
  end

  def down do
    drop_if_exists(retention_index())
  end

  defp retention_index do
    index(:meetings, [:verification_deadline_at],
      where: "verification_deadline_at IS NOT NULL AND email_verified_at IS NULL",
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
