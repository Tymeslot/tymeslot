defmodule Tymeslot.Repo.Migrations.AddInvitationToUsers do
  @moduledoc """
  Adds the invitation an admin can send to a new account: the hash of its
  single-use token, and when it was sent (the token's lifetime runs from
  then). Both are nullable and every existing row starts with neither. The
  columns are added only if missing, so a run after an interrupted one may
  meet hashes already written; any duplicate among them is cleared (that
  invitation's link stops working and the admin can resend it) before the
  unique index is built.

  The index is built concurrently, so the migration cannot run in a
  transaction. An interrupted build leaves an invalid index of this name
  behind, which the next run drops before building again.
  """

  use Ecto.Migration

  # The deduplication is a single UPDATE over a column this migration adds,
  # outside a transaction because the index is built concurrently.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # excellent_migrations:safety-assured-for-this-file operation_update
  # `down/0` drops only the two columns `up/0` added.
  # excellent_migrations:safety-assured-for-this-file column_removed

  @disable_ddl_transaction true
  @disable_migration_lock true

  @name :users_invitation_token_hash_index

  def up do
    alter table(:users) do
      add_if_not_exists(:invitation_token_hash, :string)
      add_if_not_exists(:invitation_sent_at, :utc_datetime)
    end

    execute("""
    UPDATE users SET invitation_token_hash = NULL
    WHERE id IN (
      SELECT id FROM (
        SELECT id,
               ROW_NUMBER() OVER (PARTITION BY invitation_token_hash ORDER BY id) AS rn
        FROM users
        WHERE invitation_token_hash IS NOT NULL
      ) ranked
      WHERE rn > 1
    )
    """)

    drop_if_exists(index(:users, [:invitation_token_hash], name: @name, concurrently: true))

    create(
      unique_index(:users, [:invitation_token_hash], name: @name, concurrently: true)
    )
  end

  def down do
    drop_if_exists(index(:users, [:invitation_token_hash], name: @name, concurrently: true))

    alter table(:users) do
      remove_if_exists(:invitation_sent_at, :utc_datetime)
      remove_if_exists(:invitation_token_hash, :string)
    end
  end
end
