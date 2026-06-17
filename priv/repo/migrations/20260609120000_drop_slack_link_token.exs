defmodule Tymeslot.Repo.Migrations.DropSlackLinkToken do
  use Ecto.Migration

  # `link_token` was never written or read by application code — it was dead
  # from the start. Drop the partial unique index and the column for users who
  # already ran the original create migration. Fresh installs no longer create
  # either (the original migration was patched), so this repair is idempotent
  # via IF EXISTS and safe in any prior state.

  def up do
    execute("DROP INDEX IF EXISTS slack_integrations_link_token_index")

    execute("ALTER TABLE slack_integrations DROP COLUMN IF EXISTS link_token")
  end

  def down do
    # Recreate the column and partial unique index so the migration is
    # reversible. The column was always nullable and unwritten, so no backfill
    # is needed.
    alter table(:slack_integrations) do
      add_if_not_exists(:link_token, :string)
    end

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS slack_integrations_link_token_index
    ON slack_integrations (link_token)
    WHERE link_token IS NOT NULL
    """)
  end
end
