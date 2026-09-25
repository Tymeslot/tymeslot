defmodule Tymeslot.Auth.Session do
  @moduledoc """
  Sign-in sessions as the domain sees them: the session token and its row,
  who it belongs to, and revoking it (including disconnecting any live socket
  still bound to it).

  Carrying the token in the browser (the Plug session and its
  `live_socket_id`) is the web layer's job; see `TymeslotWeb.UserAuth`.
  """

  require Logger
  alias Tymeslot.Auth.{UserQueries, UserSchema, UserSessionQueries}
  alias Tymeslot.Security.{SecurityLogger, Token}
  alias TymeslotWeb.Endpoint

  @session_ttl_hours 24

  @doc """
  Creates a session for `user_id`: stores a fresh token's row, records the
  sign-in as the user's latest activity, audits it, and returns the token.

  ## Options
    - `:replacing` - the token of a session the same browser already
      carries. It is revoked first (row deleted, live socket disconnected), so
      signing in again never leaves the previous token usable until it
      expires.
    - `:ip`, `:user_agent` - the client, for the audit entry
  """
  @spec create_session(pos_integer(), keyword()) ::
          {:ok, String.t()} | {:error, :session_creation_failed, String.t()}
  def create_session(user_id, opts \\ []) do
    revoke_token(opts[:replacing])

    token = Token.generate_session_token()

    expires_at =
      DateTime.truncate(DateTime.add(DateTime.utc_now(), @session_ttl_hours, :hour), :second)

    case UserSessionQueries.create_session(user_id, token, expires_at) do
      {:ok, _session} ->
        # Record login as the user's most recent activity (inactivity tracking).
        UserQueries.touch_last_active_at(user_id)
        SecurityLogger.log_session_event("created", user_id, token, audit_details(opts))
        {:ok, token}

      {:error, changeset} ->
        Logger.error("Failed to create session", error: inspect(changeset))
        {:error, :session_creation_failed, "Failed to create session"}
    end
  end

  @doc """
  The `live_socket_id` topic a browser carrying `token` joins, so revoking the
  session can force its socket closed.

  It is derived from the token *hash*, so it can be reconstructed at
  revocation time, which only has the stored hash. The web layer writes it
  into the signed session cookie once, when the session is created, and never
  recomputes it; see the caveat on `live_socket_topic/1` for the resulting
  pre-deploy live-socket gap.
  """
  @spec live_socket_id(String.t()) :: String.t()
  def live_socket_id(token) when is_binary(token),
    do: token |> Token.hash_token() |> live_socket_topic()

  @doc """
  The user a session token belongs to, or `nil` when it no longer maps to a
  live session row (expired, revoked, or never valid).
  """
  @spec get_user_by_token(String.t() | nil) :: UserSchema.t() | nil
  def get_user_by_token(token) when is_binary(token),
    do: UserSessionQueries.get_user_by_session_token(token)

  def get_user_by_token(_token), do: nil

  @doc """
  Ends the session `token` names: audits it, deletes its row and disconnects
  any live socket bound to it. A `nil` token is a no-op.

  `opts` carries the client (`:ip`, `:user_agent`) for the audit entry.
  """
  @spec delete_session(String.t() | nil, keyword()) :: :ok
  def delete_session(token, opts \\ [])

  def delete_session(nil, _opts), do: :ok

  def delete_session(token, opts) when is_binary(token) do
    case UserSessionQueries.get_user_by_session_token(token) do
      %{id: user_id} ->
        SecurityLogger.log_session_event("deleted", user_id, token, audit_details(opts))

      _other ->
        nil
    end

    revoke_token(token)
  end

  @doc """
  Revokes every session belonging to a user: deletes the rows and immediately
  disconnects any live sockets still bound to them.

  Used by the security flows that invalidate all sessions at once (password
  reset, password change, email change). Without the disconnect, a revoked
  session keeps working on an already-connected LiveView socket until it next
  reconnects.
  """
  @spec revoke_all_sessions(integer()) :: :ok
  def revoke_all_sessions(user_id) do
    hashes = UserSessionQueries.list_user_session_token_hashes(user_id)
    UserSessionQueries.delete_user_sessions(user_id)
    Enum.each(hashes, &disconnect_session_hash/1)
    :ok
  end

  @doc """
  Force-disconnects any live socket bound to the given session token hash by
  broadcasting a "disconnect" event on its `live_socket_id` topic.

  Takes the SHA-256 hash of the session token (the socket's topic is derived
  from the hash). Callers that delete the session row inside a database
  transaction must invoke this only after the transaction has committed —
  disconnecting a socket whose revocation later rolls back would be incorrect.
  """
  @spec disconnect_session_hash(String.t()) :: :ok
  def disconnect_session_hash(token_hash) when is_binary(token_hash) do
    Endpoint.broadcast(live_socket_topic(token_hash), "disconnect", %{})
    :ok
  end

  # Deletes one session row and disconnects any live socket bound to it.
  defp revoke_token(nil), do: :ok

  defp revoke_token(token) when is_binary(token) do
    UserSessionQueries.delete_session_by_token(token)
    disconnect_session_hash(Token.hash_token(token))
  end

  # The `live_socket_id` topic a connected socket is subscribed to, derived from
  # its session token *hash* so revocation (which only has the stored hash) can
  # reconstruct the same topic. Broadcasting "disconnect" here closes the socket.
  #
  # DEPLOY-WINDOW CAVEAT: `live_socket_id` is written into the signed session
  # cookie once, at sign-in, and is never recomputed for the life of
  # that cookie. Sessions issued *before* this hash-based topic shipped carry a
  # `live_socket_id` computed from the old (plaintext-derived) scheme, so
  # broadcasting to the new hash topic will not reach their sockets — a
  # password/email change or logout won't force-close them. Those stale
  # sessions still get cleared correctly on their *next* HTTP request once
  # their `user_sessions` row is revoked (`get_user_by_token/1` will fail to
  # resolve the deleted row), so the gap is a live-socket-disconnect miss only,
  # bounded by the 24h session validity window, not a permanent security hole.
  defp live_socket_topic(token_hash), do: "users_sessions:#{Base.url_encode64(token_hash)}"

  defp audit_details(opts), do: %{ip_address: opts[:ip], user_agent: opts[:user_agent]}
end
