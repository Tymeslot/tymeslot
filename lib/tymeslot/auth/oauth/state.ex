defmodule Tymeslot.Auth.OAuth.State do
  @moduledoc """
  Handles OAuth state generation, validation, and cleanup in the session.
  """

  import Plug.Conn

  @state_session_key "_oauth_state"

  @doc """
  Generates a secure OAuth2 state parameter and stores it in the session.

  Returns {conn, state}.
  """
  @spec generate_and_store_state(Plug.Conn.t()) :: {Plug.Conn.t(), String.t()}
  def generate_and_store_state(conn) do
    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {put_session(conn, @state_session_key, state), state}
  end

  @doc """
  Validates the OAuth2 state parameter against the stored session value.

  Returns :ok if valid, {:error, :invalid_state} otherwise.
  """
  @spec validate_state(Plug.Conn.t(), String.t() | nil) :: :ok | {:error, :invalid_state}
  def validate_state(conn, received_state) when is_binary(received_state) do
    stored_state = get_session(conn, @state_session_key)

    case stored_state do
      ^received_state when is_binary(stored_state) -> :ok
      _ -> {:error, :invalid_state}
    end
  end

  def validate_state(_conn, _), do: {:error, :invalid_state}

  @doc """
  Clears the OAuth state from the session after validation.
  """
  @spec clear_oauth_state(Plug.Conn.t()) :: Plug.Conn.t()
  def clear_oauth_state(conn), do: delete_session(conn, @state_session_key)
end
