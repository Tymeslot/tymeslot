defmodule Tymeslot.Auth.HashUserSessionTokensBackfillTest do
  @moduledoc """
  Drives `20260702214204_hash_user_session_tokens`: for each pre-existing
  session row, its plaintext `token` is hashed into `token_hash`, and the
  plaintext column is then dropped.

  `down/0` raises on purpose — plaintext tokens cannot be recovered from their
  hashes — so the pre-migration schema is reconstructed by hand in `setup`
  and the recorded version dropped from the ledger, after which the real
  migration runs over it. Everything is reverted by the sandbox transaction
  rollback at test end. See `Tymeslot.Test.MigrationRunner`.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations

  alias Tymeslot.Auth.UserSessionQueries
  alias Tymeslot.Repo
  alias Tymeslot.Security.Token
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_702_214_204

  setup do
    # The pre-migration shape: a plaintext `token` column carrying the unique
    # index the migration drops, and no `token_hash` yet.
    Repo.query!("ALTER TABLE user_sessions DROP COLUMN token_hash")
    Repo.query!("ALTER TABLE user_sessions ADD COLUMN token character varying")
    Repo.query!("CREATE UNIQUE INDEX user_sessions_token_index ON user_sessions (token)")

    MigrationRunner.forget!(@version)

    :ok
  end

  test "backfill sets token_hash to the SHA-256 hash of the plaintext token" do
    user = insert(:user)
    plaintext = seed_session(user)

    MigrationRunner.up!(@version)

    assert token_hash_for(user) == Token.hash_token(plaintext)
  end

  test "a session lookup by the original plaintext token resolves after the backfill" do
    user = insert(:user)
    plaintext = seed_session(user)

    MigrationRunner.up!(@version)

    assert %{id: resolved_id} = UserSessionQueries.get_user_by_session_token(plaintext)
    assert resolved_id == user.id
  end

  test "the plaintext column is gone and token_hash is mandatory afterwards" do
    user = insert(:user)
    seed_session(user)

    MigrationRunner.up!(@version)

    refute column_exists?("user_sessions", "token")
    assert column_not_null?("user_sessions", "token_hash")
  end

  # -- Helpers ----------------------------------------------------------------

  # Written past the schema: `token_hash` does not exist yet at this point,
  # which is the whole shape the migration has to repair.
  defp seed_session(user) do
    plaintext = "seed-plaintext-token-#{System.unique_integer([:positive])}"

    Repo.query!(
      """
      INSERT INTO user_sessions (user_id, token, expires_at, inserted_at, updated_at)
      VALUES ($1, $2, NOW() + INTERVAL '24 hours', NOW(), NOW())
      """,
      [user.id, plaintext]
    )

    plaintext
  end

  defp token_hash_for(user) do
    %{rows: [[value]]} =
      Repo.query!("SELECT token_hash FROM user_sessions WHERE user_id = $1", [user.id])

    value
  end

  defp column_exists?(table, column) do
    %{rows: [[exists]]} =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_name = $1 AND column_name = $2
        )
        """,
        [table, column]
      )

    exists
  end

  defp column_not_null?(table, column) do
    %{rows: [[nullable]]} =
      Repo.query!(
        """
        SELECT is_nullable FROM information_schema.columns
        WHERE table_name = $1 AND column_name = $2
        """,
        [table, column]
      )

    nullable == "NO"
  end
end
