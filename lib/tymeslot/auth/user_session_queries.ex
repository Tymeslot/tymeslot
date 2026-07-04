defmodule Tymeslot.Auth.UserSessionQueries do
  @moduledoc """
  Query interface for user session operations.
  """
  import Ecto.Query, warn: false
  alias Tymeslot.Auth.{UserSchema, UserSessionSchema}
  alias Tymeslot.Repo
  alias Tymeslot.Security.Token

  @doc """
  Creates a session for a user. The plaintext `token` is hashed before storage;
  only its hash is persisted.
  """
  @spec create_session(integer(), String.t(), DateTime.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def create_session(user_id, token, expires_at) do
    %UserSessionSchema{}
    |> UserSessionSchema.changeset(%{
      user_id: user_id,
      token_hash: hash_token(token),
      expires_at: expires_at
    })
    |> Repo.insert()
  end

  defp hash_token(token) when is_binary(token), do: Token.hash_token(token)
  defp hash_token(_token), do: nil

  @doc """
  Gets a user by session token. The plaintext `token` is hashed and matched
  against the stored hash.
  """
  @spec get_user_by_session_token(String.t()) :: Ecto.Schema.t() | nil
  def get_user_by_session_token(token) when is_binary(token) do
    token_hash = Token.hash_token(token)

    query =
      from(s in UserSessionSchema,
        join: u in UserSchema,
        on: s.user_id == u.id,
        where: s.token_hash == ^token_hash and s.expires_at > ^DateTime.utc_now(),
        select: u
      )

    Repo.one(query)
  end

  @doc """
  Lists the token hashes of all sessions belonging to a user.

  Used to force-disconnect any live sockets bound to those sessions when the
  sessions are revoked (password reset, password change, email change). The
  socket's `live_socket_id` is derived from the token hash, so these values map
  directly to the topics to broadcast a disconnect on.
  """
  @spec list_user_session_token_hashes(integer()) :: [String.t()]
  def list_user_session_token_hashes(user_id) do
    query =
      from(s in UserSessionSchema,
        where: s.user_id == ^user_id,
        select: s.token_hash
      )

    Repo.all(query)
  end

  @doc """
  Deletes all sessions for a user.
  """
  @spec delete_user_sessions(integer()) :: {non_neg_integer(), nil}
  def delete_user_sessions(user_id) do
    query =
      from(s in UserSessionSchema,
        where: s.user_id == ^user_id
      )

    Repo.delete_all(query)
  end

  @doc """
  Deletes a specific session by token. The plaintext `token` is hashed and
  matched against the stored hash.
  """
  @spec delete_session_by_token(String.t()) :: {non_neg_integer(), nil}
  def delete_session_by_token(token) when is_binary(token) do
    token_hash = Token.hash_token(token)

    query =
      from(s in UserSessionSchema,
        where: s.token_hash == ^token_hash
      )

    Repo.delete_all(query)
  end

  @doc """
  Cleans up expired sessions.
  """
  @spec cleanup_expired_sessions() :: {non_neg_integer(), nil}
  def cleanup_expired_sessions do
    query =
      from(s in UserSessionSchema,
        where: s.expires_at <= ^DateTime.utc_now()
      )

    Repo.delete_all(query)
  end
end
