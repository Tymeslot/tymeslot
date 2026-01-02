defmodule Tymeslot.Repo.Migrations.BackfillResetTokenHash do
  use Ecto.Migration

  def up do
    # Ensure pgcrypto extension is available for digest()
    execute "CREATE EXTENSION IF NOT EXISTS pgcrypto"

    # Backfill token hash from existing plaintext reset_token (if any)
    execute "UPDATE users SET reset_token_hash = lower(encode(digest(CAST(reset_token AS bytea), 'sha256'), 'hex')) WHERE reset_token IS NOT NULL AND reset_token_hash IS NULL"
  end

  def down do
    :ok
  end
end