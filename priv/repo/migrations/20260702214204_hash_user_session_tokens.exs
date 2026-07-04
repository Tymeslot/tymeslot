defmodule Tymeslot.Repo.Migrations.HashUserSessionTokens do
  @moduledoc """
  Stores session tokens hashed at rest, matching the one-time auth tokens
  (reset/verification/email-change) which are already SHA-256 hashed. A DB dump
  or read-only SQLi previously yielded immediately-usable 24h session tokens.

  The plaintext token still lives in the user's cookie; only its SHA-256 hash is
  stored and matched. Existing sessions are backfilled (hash of their current
  plaintext token) so nobody is logged out. The hash is
  `Base.encode16(sha256(token), :lower)` — inlined here to keep the migration
  independent of application code, matching `Tymeslot.Security.Token.hash_token/1`.
  """

  use Ecto.Migration
  import Ecto.Query

  def up do
    alter table(:user_sessions) do
      add(:token_hash, :string)
    end

    flush()

    backfill_hashes()

    create(unique_index(:user_sessions, [:token_hash]))

    drop(unique_index(:user_sessions, [:token]))

    alter table(:user_sessions) do
      modify(:token_hash, :string, null: false)
      remove(:token)
    end
  end

  def down do
    raise "irreversible: plaintext session tokens are not recoverable from their hashes"
  end

  defp backfill_hashes do
    repo().all(from(s in "user_sessions", select: {s.id, s.token}))
    |> Enum.each(fn {id, token} ->
      hash = Base.encode16(:crypto.hash(:sha256, token), case: :lower)

      repo().update_all(
        from(s in "user_sessions", where: s.id == ^id),
        set: [token_hash: hash]
      )
    end)
  end
end
