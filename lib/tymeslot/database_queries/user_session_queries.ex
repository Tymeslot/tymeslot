defmodule Tymeslot.DatabaseQueries.UserSessionQueries do
  @moduledoc """
  Query interface for user session operations.
  """
  import Ecto.Query, warn: false
  alias Tymeslot.DatabaseSchemas.{UserSchema, UserSessionSchema}
  alias Tymeslot.Repo

  @doc """
  Creates a session for a user.
  """
  @spec create_session(integer(), String.t(), DateTime.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def create_session(user_id, token, expires_at) do
    %UserSessionSchema{}
    |> UserSessionSchema.changeset(%{
      user_id: user_id,
      token: token,
      expires_at: expires_at
    })
    |> Repo.insert()
  end

  @doc """
  Gets a user by session token.
  """
  @spec get_user_by_session_token(String.t()) :: Ecto.Schema.t() | nil
  def get_user_by_session_token(token) when is_binary(token) do
    query =
      from(s in UserSessionSchema,
        join: u in UserSchema,
        on: s.user_id == u.id,
        where: s.token == ^token and s.expires_at > ^DateTime.utc_now(),
        select: u
      )

    Repo.one(query)
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
  Deletes a specific session by token.
  """
  @spec delete_session_by_token(String.t()) :: {non_neg_integer(), nil}
  def delete_session_by_token(token) when is_binary(token) do
    query =
      from(s in UserSessionSchema,
        where: s.token == ^token
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
        where: s.expires_at < ^DateTime.utc_now()
      )

    Repo.delete_all(query)
  end
end
