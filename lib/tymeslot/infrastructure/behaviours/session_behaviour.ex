defmodule Tymeslot.Infrastructure.SessionBehaviour do
  @moduledoc """
  Behaviour specification for session management.
  """

  @doc """
  Creates a session for the given user, stores the session token in the database and Plug.Conn session.
  Returns {:ok, conn, token} on success, or {:error, reason, details} on failure.
  """
  @type user_with_id :: %{required(:id) => pos_integer(), optional(atom()) => term()}

  @callback create_session(Plug.Conn.t(), user_with_id()) ::
              {:ok, Plug.Conn.t(), String.t()} | {:error, atom(), any()}

  @doc """
  Deletes the session token from the Plug.Conn session.
  Returns the updated conn.
  """
  @callback delete_session(Plug.Conn.t()) :: Plug.Conn.t()
end
