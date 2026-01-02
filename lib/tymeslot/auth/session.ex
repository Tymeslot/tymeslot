defmodule Tymeslot.Auth.Session do
  @moduledoc """
  Handles session token creation, storage, and Plug.Conn session management.
  """
  @behaviour Tymeslot.Infrastructure.SessionBehaviour

  require Logger
  alias Phoenix.Component
  alias Plug.Conn
  alias Tymeslot.DatabaseQueries.UserSessionQueries
  alias Tymeslot.Security.{SecurityLogger, Token}

  @user_token_key :user_token

  @doc """
  Creates a session for the given user, stores the session token in the database.
  For Plug.Conn: also stores in the connection session.
  For LiveView sockets: stores in socket assigns.
  Returns {:ok, conn_or_socket, token} on success, or {:error, reason, details} on failure.
  """
  @spec create_session(Conn.t() | Phoenix.LiveView.Socket.t(), map()) ::
          {:ok, Conn.t() | Phoenix.LiveView.Socket.t(), String.t()} | {:error, atom(), any()}
  def create_session(conn_or_socket, user) do
    token = Token.generate_session_token()
    expires_at = DateTime.truncate(DateTime.add(DateTime.utc_now(), 24, :hour), :second)

    case UserSessionQueries.create_session(user.id, token, expires_at) do
      {:ok, _session} ->
        result =
          case conn_or_socket do
            %Conn{} = conn ->
              updated_conn =
                conn
                |> Conn.put_session(@user_token_key, token)
                |> Conn.put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")
                |> Conn.configure_session(renew: true)

              # Log session creation for Plug.Conn
              SecurityLogger.log_session_event("created", user.id, token, %{
                ip_address: get_peer_data(conn)[:address],
                user_agent: List.first(Conn.get_req_header(conn, "user-agent"))
              })

              {:ok, updated_conn, token}

            %Phoenix.LiveView.Socket{} = socket ->
              updated_socket = %{
                socket
                | assigns:
                    Map.merge(socket.assigns, %{
                      user_token: token,
                      current_user: user,
                      live_socket_id: "users_sessions:#{Base.url_encode64(token)}"
                    })
              }

              # Log session creation for LiveView socket
              SecurityLogger.log_session_event("created", user.id, token, %{
                ip_address: socket.assigns[:client_ip] || "unknown",
                user_agent: "liveview"
              })

              {:ok, updated_socket, token}
          end

        result

      {:error, changeset} ->
        Logger.error("Failed to create session: #{inspect(changeset)}")
        {:error, :session_creation_failed, "Failed to create session"}
    end
  end

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

        _ ->
          nil
      end

      UserSessionQueries.delete_session_by_token(user_token)
    end

    conn
    |> Conn.configure_session(drop: true)
    |> Conn.clear_session()
  end

  @doc """
  Retrieves the current user ID from the session token in Plug.Conn session.
  Returns the user ID or nil if not found or invalid.
  """
  @spec get_current_user_id(Conn.t()) :: integer() | nil
  def get_current_user_id(conn) do
    with token when not is_nil(token) <- Conn.get_session(conn, @user_token_key),
         %{id: id} <- UserSessionQueries.get_user_by_session_token(token) do
      id
    else
      _ -> nil
    end
  end

  @doc """
  Get unverified user from session data.
  Used during email verification flow to track incomplete registrations.
  """
  @spec get_unverified_user_from_session(map()) :: map() | nil
  def get_unverified_user_from_session(session) do
    # Check if session has unverified user data and it's not expired (30 min)
    with user_id when not is_nil(user_id) <- session["unverified_user_id"],
         email when not is_nil(email) <- session["unverified_user_email"],
         timestamp when not is_nil(timestamp) <- session["unverified_session_timestamp"],
         true <- session_valid?(timestamp) do
      %{
        id: user_id,
        email: email,
        timestamp: timestamp
      }
    else
      _ -> nil
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

  # Helper function to safely get peer data
  defp get_peer_data(conn) do
    peer_data = Conn.get_peer_data(conn)

    # Dialyzer tells us peer_data always has :address field with tuple value
    address =
      case peer_data.address do
        addr when is_tuple(addr) and tuple_size(addr) in [4, 8] ->
          to_string(:inet.ntoa(addr))

        _ ->
          "unknown"
      end

    %{address: address}
  rescue
    error ->
      Logger.error("Unexpected error getting peer data: #{inspect(error)}")
      %{address: "unknown"}
  end
end
