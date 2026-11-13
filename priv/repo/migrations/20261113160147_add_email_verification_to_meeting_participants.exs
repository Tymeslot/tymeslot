defmodule Tymeslot.Repo.Migrations.AddEmailVerificationToMeetingParticipants do
  @moduledoc """
  Lets a group seat wait for its booker to verify their email address.

  A group slot is one `meetings` row with a `meeting_participants` row per
  seat, and a seat has no status of its own, so the gate lives on the seat:
  `verification_deadline_at` (when the hold lapses) and `email_verified_at`.
  Both `NULL` means an ungated seat, which is true of every existing row, so
  there is nothing to backfill.

  A small partial index serves the sweep that expires lapsed holds. It is
  built `CONCURRENTLY`, so neither the DDL transaction nor the migration lock
  can be held; `create_if_not_exists` makes a re-run a no-op.
  """

  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file column_removed
  # The only columns removed are this migration's own, nullable ones, in `down/0`.

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    alter table(:meeting_participants) do
      add_if_not_exists(:verification_deadline_at, :utc_datetime)
      add_if_not_exists(:email_verified_at, :utc_datetime)
    end

    create_if_not_exists(
      index(:meeting_participants, [:verification_deadline_at],
        where:
          "email_verified_at IS NULL AND cancelled_at IS NULL AND verification_deadline_at IS NOT NULL",
        name: :meeting_participants_unverified_deadline_index,
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:meeting_participants, [:verification_deadline_at],
        name: :meeting_participants_unverified_deadline_index,
        concurrently: true
      )
    )

    alter table(:meeting_participants) do
      remove_if_exists(:verification_deadline_at, :utc_datetime)
      remove_if_exists(:email_verified_at, :utc_datetime)
    end
  end
end
