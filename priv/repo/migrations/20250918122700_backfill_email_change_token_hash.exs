defmodule Tymeslot.Repo.Migrations.BackfillEmailChangeTokenHash do
  use Ecto.Migration

  def up do
    # Ensure pgcrypto extension is available for digest()
    execute "CREATE EXTENSION IF NOT EXISTS pgcrypto"

    # Backfill token hash from existing plaintext token (if any)
    # Use PostgreSQL encode + sha256 hashing on text by first converting to bytea
    execute "UPDATE users SET email_change_token_hash = lower(encode(digest(CAST(email_change_token AS bytea), 'sha256'), 'hex')) WHERE email_change_token IS NOT NULL AND email_change_token_hash IS NULL"
  end

  def down do
    :ok
  end
end
