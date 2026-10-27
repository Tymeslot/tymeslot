defmodule Tymeslot.Repo.Migrations.AddConfirmationToPollParticipants do
  use Ecto.Migration

  @moduledoc """
  Adds email confirmation to poll participants.

  A participant now gets their personal voting link only by email, and their
  responses count from the first time they save them through it. `link_sent_at`
  throttles and expires those links; `confirmed_at` marks the participant whose
  responses count.

  Everyone already on a poll registered under the old rules and may have voted,
  so they are confirmed here rather than dropped from polls that are still
  running. Their `?p=` links keep working.
  """

  def up do
    alter table(:poll_participants) do
      add :confirmed_at, :utc_datetime
      add :link_sent_at, :utc_datetime
    end

    # The backfill is the point of the migration: everyone registered under the
    # old rules counts. One UPDATE over a small table (a row per person on a
    # poll), run before the application starts.
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("UPDATE poll_participants SET confirmed_at = COALESCE(voted_at, inserted_at)")
  end

  # The release before this one counts everyone on a poll, so a link request
  # nobody confirmed would come back as a voter. Those requests are deleted
  # first; their address can ask again. Deleting them and dropping the columns
  # is the whole point of the rollback, which only ever runs deliberately, on
  # a small table (a row per person on a poll).
  def down do
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("DELETE FROM poll_participants WHERE confirmed_at IS NULL")

    alter table(:poll_participants) do
      # excellent_migrations:safety-assured-for-next-line column_removed
      remove :confirmed_at
      # excellent_migrations:safety-assured-for-next-line column_removed
      remove :link_sent_at
    end
  end
end
