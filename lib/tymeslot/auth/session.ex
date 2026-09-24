defmodule Tymeslot.Auth.Session do
  @moduledoc """
  Handles session token creation, storage, and Plug.Conn session management,
  and resolves the signed-in user from a session.
  """
  @behaviour Tymeslot.Infrastructure.SessionBehaviour

  require Logger
  alias Phoenix.Component
  alias Plug.Conn
  alias Tymeslot.Auth.{UserQueries, UserSchema, UserSessionQueries}
  alias Tymeslot.Security.{SecurityLogger, Token}
  alias TymeslotWeb.Endpoint

  @user_token_key :user_token

  @type user_minimal :: %{required(:id) => pos_integer(), optional(atom()) => term()}
  @type unverified_user_session :: %{
          required(:id) => pos_integer(),
          required(:email) => String.t(),
          required(:timestamp) => integer()
        }

  @doc """
  Creates a session for the given user: stores the session token in the
  database and in the Plug.Conn session.

  A session already carried by the connection is revoked first (its row
  deleted and any live socket bound to it disconnected), so signing in again
  never leaves the previous token usable until it expires.

  Returns {:ok, conn, token} on success, or {:error, reason, details} on failure.
  """
  @spec create_session(Conn.t(), user_minimal()) ::
          {:ok, Conn.t(), String.t()} | {:error, atom(), any()}
  def create_session(%Conn{} = conn, user) do
    revoke_token(Conn.get_session(conn, @user_token_key))

    token = Token.generate_session_token()
    # The socket's disconnect topic is derived from the token *hash*, so it can
    # be reconstructed at revocation time (which only has the stored hash).
    # This hash is baked into `live_socket_id` below and stored, unrecomputed,
    # in the signed cookie for the session's entire life — see the caveat on
    # `live_socket_topic/1` for the resulting pre-deploy live-socket gap.
    token_hash = Token.hash_token(token)
    expires_at = DateTime.truncate(DateTime.add(DateTime.utc_now(), 24, :hour), :second)

    case UserSessionQueries.create_session(user.id, token, expires_at) do
      {:ok, _session} ->
        # Record login as the user's most recent activity (inactivity tracking).
        UserQueries.touch_last_active_at(user.id)

        updated_conn =
          conn
          |> Conn.put_session(@user_token_key, token)
          |> Conn.put_session(:live_socket_id, live_socket_topic(token_hash))
          |> Conn.configure_session(renew: true)

        SecurityLogger.log_session_event("created", user.id, token, %{
          ip_address: get_peer_data(conn)[:address],
          user_agent: List.first(Conn.get_req_header(conn, "user-agent"))
        })

        {:ok, updated_conn, token}

      {:error, changeset} ->
        Logger.error("Failed to create session", error: inspect(changeset))
        {:error, :session_creation_failed, "Failed to create session"}
    end
  end

  @doc """
  Resolves the signed-in user from a session map: a Plug session
  (`Plug.Conn.get_session/1`) or a LiveView mount session, both keyed by
  strings.

  Returns `nil` when the session carries no token, or when the token no
  longer maps to a live session row (expired, revoked, or never valid).
  """
  @spec user_from_session(map()) :: UserSchema.t() | nil
  def user_from_session(%{"user_token" => token}) when is_binary(token) do
    UserSessionQueries.get_user_by_session_token(token)
  end

  def user_from_session(_session), do: nil

  @doc """
  Deletes the session token from the Plug.Conn session.
  Returns the updated conn.
  """
  @spec delete_session(Conn.t()) :: Conn.t()
  def delete_session(conn) do
    user_token = Conn.get_session(conn, @user_token_key)

    if user_token do
      # Log session deletion before removing it
      case UserSessionQueries.get_user_by_session_token(user_token) do
        %{id: user_id} ->
          SecurityLogger.log_session_event("deleted", user_id, user_token, %{
            ip_address: get_peer_data(conn)[:address],
            user_agent: List.first(Conn.get_req_header(conn, "user-agent"))
          })

        _other ->
          nil
      end

      revoke_token(user_token)
    end

    conn
    |> Conn.configure_session(drop: true)
    |> Conn.clear_session()
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

  @doc """
  Remembers an unverified user in the Plug session, so the verify-email page
  can offer to resend their link.

  Only call this once the user has proved their password: whoever holds this
  session can have the verification email resent, which rotates the pending
  link. `get_unverified_user_from_session/1` reads it back.
  """
  @spec put_unverified_user(Conn.t(), user_minimal()) :: Conn.t()
  def put_unverified_user(conn, %{id: id, email: email}) do
    conn
    |> Conn.put_session(:unverified_user_id, id)
    |> Conn.put_session(:unverified_user_email, email)
    |> Conn.put_session(:unverified_session_timestamp, DateTime.to_unix(DateTime.utc_now()))
  end

  @doc """
  Forgets the unverified user stored by `put_unverified_user/2`.
  """
  @spec clear_unverified_user(Conn.t()) :: Conn.t()
  def clear_unverified_user(conn) do
    conn
    |> Conn.delete_session(:unverified_user_id)
    |> Conn.delete_session(:unverified_user_email)
    |> Conn.delete_session(:unverified_session_timestamp)
  end

  @doc """
  Get unverified user from session data.
  Used during email verification flow to track incomplete registrations.
  """
  @spec get_unverified_user_from_session(map()) :: unverified_user_session() | nil
  def get_unverified_user_from_session(session) do
    # Check if session has unverified user data and it's not expired (30 min)
    with user_id when is_integer(user_id) <- session["unverified_user_id"],
         email when is_binary(email) <- session["unverified_user_email"],
         timestamp when is_integer(timestamp) <- session["unverified_session_timestamp"],
         true <- session_valid?(timestamp) do
      %{
        id: user_id,
        email: email,
        timestamp: timestamp
      }
    else
      _other -> nil
    end
  end

  @doc """
  Check if unverified session is still valid (30 minutes).
  """
  @spec session_valid?(integer()) :: boolean()
  def session_valid?(timestamp) do
    current_time = DateTime.to_unix(DateTime.utc_now())
    # 30 minutes = 1800 seconds
    current_time - timestamp < 1800
  end

  @doc """
  Populate unverified user data in socket assigns if in verify_email state.
  """
  @spec populate_unverified_user_data(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def populate_unverified_user_data(socket) do
    if socket.assigns.current_state == :verify_email && socket.assigns.unverified_user do
      Component.assign(socket, :form_data, %{email: socket.assigns.unverified_user.email})
    else
      socket
    end
  end

  @doc """
  Get verification email from either unverified session or form_data.
  """
  @spec get_verification_email(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  def get_verification_email(socket) do
    # First check unverified user from session
    if socket.assigns[:unverified_user] do
      socket.assigns.unverified_user.email
    else
      # Fall back to form_data (signup flow)
      get_in(socket.assigns, [:form_data, :email])
    end
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
  # cookie once, at `create_session/2`, and is never recomputed for the life of
  # that cookie. Sessions issued *before* this hash-based topic shipped carry a
  # `live_socket_id` computed from the old (plaintext-derived) scheme, so
  # broadcasting to the new hash topic will not reach their sockets — a
  # password/email change or logout won't force-close them. Those stale
  # sessions still get cleared correctly on their *next* HTTP request once
  # their `user_sessions` row is revoked (`user_from_session/1` will fail to
  # resolve the deleted row), so the gap is a live-socket-disconnect miss only,
  # bounded by the 24h session validity window, not a permanent security hole.
  defp live_socket_topic(token_hash), do: "users_sessions:#{Base.url_encode64(token_hash)}"

  # Helper function to safely get peer data
  defp get_peer_data(conn) do
    peer_data = Conn.get_peer_data(conn)

    # Dialyzer tells us peer_data always has :address field with tuple value
    address =
      case peer_data.address do
        addr when is_tuple(addr) and tuple_size(addr) in [4, 8] ->
          to_string(:inet.ntoa(addr))

        _other ->
          "unknown"
      end

    %{address: address}
  rescue
    error ->
      Logger.error("Unexpected error getting peer data", error: inspect(error))
      %{address: "unknown"}
  end
end
