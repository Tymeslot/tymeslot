defmodule Tymeslot.Infrastructure.SessionBehaviour do
  @moduledoc """
  Behaviour specification for session management.
  """

  @doc """
  Creates a session for the given user, stores the session token in the database and Plug.Conn session.
  Returns {:ok, conn, token} on success, or {:error, reason, details} on failure.
  """
  @callback create_session(Plug.Conn.t(), map()) ::
              {:ok, Plug.Conn.t(), String.t()} | {:error, atom(), any()}

  @doc """
  Deletes the session token from the Plug.Conn session.
  Returns the updated conn.
  """
  @callback delete_session(Plug.Conn.t()) :: Plug.Conn.t()

  @doc """
  Retrieves the current user ID from the session token in Plug.Conn session.
  Returns the user ID or nil if not found or invalid.
  """
  @callback get_current_user_id(Plug.Conn.t()) :: integer() | nil
end
