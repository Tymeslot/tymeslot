defmodule TymeslotWeb.OAuthFlow.State do
  @moduledoc """
  Keeps the per-flow OAuth secrets in the session: the `state` parameter that
  ties the callback to the browser that started the flow (CSRF), and the PKCE
  code verifier (RFC 7636) that ties the authorisation code to it.

  Both are issued together at the start of a flow, expire together after ten
  minutes, and are cleared together once the callback has used them.
  """

  import Plug.Conn

  alias Plug.Crypto

  @state_session_key "_oauth_state"
  @state_ttl_seconds 600

  @type flow_params :: %{state: String.t(), code_challenge: String.t()}

  @doc """
  Issues a fresh state and PKCE code verifier, stores them in the session with
  the time of issue, and returns the values the authorise URL carries: the
  state and the S256 code challenge.
  """
  @spec generate_and_store_state(Plug.Conn.t()) :: {Plug.Conn.t(), flow_params()}
  def generate_and_store_state(conn) do
    state = random_token()
    code_verifier = random_token()
    entry = {state, code_verifier, System.system_time(:second)}

    {put_session(conn, @state_session_key, entry),
     %{state: state, code_challenge: code_challenge(code_verifier)}}
  end

  @doc """
  Checks the state the provider echoed back against the stored one (constant
  time, within the TTL) and returns the PKCE code verifier for the token
  exchange.
  """
  @spec validate_state(Plug.Conn.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :invalid_state}
  def validate_state(conn, received_state) when is_binary(received_state) do
    case get_session(conn, @state_session_key) do
      {stored_state, code_verifier, issued_at} when is_binary(stored_state) ->
        if Crypto.secure_compare(stored_state, received_state) and not expired?(issued_at),
          do: {:ok, code_verifier},
          else: {:error, :invalid_state}

      _missing_or_malformed ->
        {:error, :invalid_state}
    end
  end

  def validate_state(_conn, _invalid_state), do: {:error, :invalid_state}

  @doc """
  Clears the state and code verifier from the session.
  """
  @spec clear_oauth_state(Plug.Conn.t()) :: Plug.Conn.t()
  def clear_oauth_state(conn), do: delete_session(conn, @state_session_key)

  @doc """
  The S256 PKCE code challenge for a code verifier.
  """
  @spec code_challenge(String.t()) :: String.t()
  def code_challenge(code_verifier),
    do: Base.url_encode64(:crypto.hash(:sha256, code_verifier), padding: false)

  # 32 random bytes, url-safe base64 without padding: 43 characters, which is
  # also the shortest code verifier RFC 7636 allows.
  defp random_token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp expired?(issued_at) do
    System.system_time(:second) - issued_at > @state_ttl_seconds
  end
end
