defmodule Tymeslot.Auth.HashUserSessionTokensBackfillTest do
  @moduledoc """
  Exercises the backfill from 20260702214204_hash_user_session_tokens: for
  each pre-existing session row, its plaintext `token` is hashed into
  `token_hash`. The migration drops the plaintext `token` column from the
  live schema, so this test temporarily reconstructs it to run the exact
  backfill statement — reverted automatically by the sandbox transaction
  rollback at test end.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations

  alias Tymeslot.Auth.UserSessionQueries
  alias Tymeslot.Repo
  alias Tymeslot.Security.Token

  setup do
    Repo.query!("ALTER TABLE user_sessions ADD COLUMN token character varying")
    :ok
  end

  test "backfill sets token_hash to the SHA-256 hash of the plaintext token" do
    user = insert(:user)
    plaintext = "seed-plaintext-token-#{System.unique_integer([:positive])}"

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO user_sessions (user_id, token, token_hash, expires_at, inserted_at, updated_at)
        VALUES ($1, $2, $3, NOW() + INTERVAL '24 hours', NOW(), NOW())
        RETURNING id
        """,
        [user.id, plaintext, "placeholder-#{System.unique_integer([:positive])}"]
      )

    run_backfill!()

    assert get_token_hash(id) == Token.hash_token(plaintext)
  end

  test "a session lookup by the original plaintext token resolves after the backfill" do
    user = insert(:user)
    plaintext = "seed-plaintext-token-#{System.unique_integer([:positive])}"

    Repo.query!(
      """
      INSERT INTO user_sessions (user_id, token, token_hash, expires_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, NOW() + INTERVAL '24 hours', NOW(), NOW())
      """,
      [user.id, plaintext, "placeholder-#{System.unique_integer([:positive])}"]
    )

    run_backfill!()

    assert %{id: resolved_id} = UserSessionQueries.get_user_by_session_token(plaintext)
    assert resolved_id == user.id
  end

  # -- Helpers ----------------------------------------------------------------

  # Mirrors the migration's `backfill_hashes/0` — read each row's plaintext
  # token, hash it, and write the hash back per row.
  defp run_backfill! do
    rows = Repo.all(from(s in "user_sessions", select: {s.id, s.token}))

    Enum.each(rows, fn {id, token} ->
      hash = Base.encode16(:crypto.hash(:sha256, token), case: :lower)

      Repo.update_all(
        from(s in "user_sessions", where: s.id == ^id),
        set: [token_hash: hash]
      )
    end)
  end

  defp get_token_hash(id) do
    %{rows: [[value]]} = Repo.query!("SELECT token_hash FROM user_sessions WHERE id = $1", [id])
    value
  end
end
