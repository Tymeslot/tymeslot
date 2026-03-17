defmodule Tymeslot.Repo.Migrations.HashExistingVerificationTokens do
  use Ecto.Migration

  def up do
    # Ensure pgcrypto extension is available for digest()
    execute "CREATE EXTENSION IF NOT EXISTS pgcrypto"

    # Verification tokens are now stored as SHA-256 hashes (matching the pattern
    # already used for reset and email-change tokens). Backfill any pending
    # plaintext tokens that exist in the database.
    execute("""
    UPDATE users
    SET verification_token = lower(encode(digest(verification_token::bytea, 'sha256'), 'hex'))
    WHERE verification_token IS NOT NULL
      AND verification_token_used_at IS NULL
      AND verified_at IS NULL
    """)
  end

  def down do
    # Hashed tokens cannot be reversed to plaintext; this migration is irreversible.
    :ok
  end
end
