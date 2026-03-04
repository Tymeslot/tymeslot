defmodule Tymeslot.Auth.OAuth.State do
  @moduledoc """
  Handles OAuth state generation, validation, and cleanup in the session.
  """

  import Plug.Conn

  alias Plug.Crypto

  @state_session_key "_oauth_state"
  @state_ttl_seconds 600

  @doc """
  Generates a secure OAuth2 state parameter and stores it in the session
  alongside a timestamp for expiry enforcement.

  Returns {conn, state}.
  """
  @spec generate_and_store_state(Plug.Conn.t()) :: {Plug.Conn.t(), String.t()}
  def generate_and_store_state(conn) do
    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    entry = {state, System.system_time(:second)}
    {put_session(conn, @state_session_key, entry), state}
  end

  @doc """
  Validates the OAuth2 state parameter against the stored session value
  using constant-time comparison and a #{@state_ttl_seconds}-second TTL.

  Returns :ok if valid, {:error, :invalid_state} otherwise.
  """
  @spec validate_state(Plug.Conn.t(), String.t() | nil) :: :ok | {:error, :invalid_state}
  def validate_state(conn, received_state) when is_binary(received_state) do
    case get_session(conn, @state_session_key) do
      {stored_state, timestamp} when is_binary(stored_state) ->
        if Crypto.secure_compare(stored_state, received_state) and
             not expired?(timestamp) do
          :ok
        else
          {:error, :invalid_state}
        end

      # Pre-upgrade sessions stored bare strings without timestamps and have no TTL enforcement.
      stored_state when is_binary(stored_state) ->
        if Crypto.secure_compare(stored_state, received_state),
          do: :ok,
          else: {:error, :invalid_state}

      _other ->
        {:error, :invalid_state}
    end
  end

  def validate_state(_conn, _invalid_state), do: {:error, :invalid_state}

  @doc """
  Clears the OAuth state from the session after validation.
  """
  @spec clear_oauth_state(Plug.Conn.t()) :: Plug.Conn.t()
  def clear_oauth_state(conn), do: delete_session(conn, @state_session_key)

  defp expired?(timestamp) do
    System.system_time(:second) - timestamp > @state_ttl_seconds
  end
end
