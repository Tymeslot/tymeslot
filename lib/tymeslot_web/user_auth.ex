defmodule TymeslotWeb.UserAuth do
  @moduledoc """
  The browser's half of signing in: carrying the session token in the Plug
  session, and remembering an unverified account for the verify-email screen.

  The token itself, its row and its revocation belong to the domain
  (`Tymeslot.Auth.Session`); this module only moves them in and out of the
  signed session cookie.
  """

  import Plug.Conn

  alias Tymeslot.Auth.{Session, UserSchema}
  alias TymeslotWeb.Helpers.ClientIP

  @user_token_key :user_token

  # How long the verify-email screen may offer a resend for an account
  # remembered by `put_unverified_user/2`.
  @unverified_ttl_seconds 30 * 60

  @type user_minimal :: %{required(:id) => pos_integer(), optional(atom()) => term()}
  @type unverified_user :: %{
          required(:id) => pos_integer(),
          required(:email) => String.t(),
          required(:timestamp) => integer()
        }

  @doc """
  Signs `user` in on this connection: creates a session (revoking one the
  connection already carried) and stores its token and `live_socket_id` in a
  renewed Plug session.

  Returns `{:ok, conn, token}` on success, or `{:error, reason, details}`.
  """
  @spec create_session(Plug.Conn.t(), user_minimal()) ::
          {:ok, Plug.Conn.t(), String.t()} | {:error, atom(), String.t()}
  def create_session(%Plug.Conn{} = conn, %{id: user_id}) do
    opts = [replacing: get_session(conn, @user_token_key)] ++ ClientIP.request_opts(conn)

    with {:ok, token} <- Session.create_session(user_id, opts) do
      conn =
        conn
        |> put_session(@user_token_key, token)
        |> put_session(:live_socket_id, Session.live_socket_id(token))
        |> configure_session(renew: true)

      {:ok, conn, token}
    end
  end

  @doc """
  Signs the connection out: ends the session its token names and drops the
  whole Plug session.
  """
  @spec delete_session(Plug.Conn.t()) :: Plug.Conn.t()
  def delete_session(conn) do
    conn
    |> get_session(@user_token_key)
    |> Session.delete_session(ClientIP.request_opts(conn))

    conn
    |> configure_session(drop: true)
    |> clear_session()
  end

  @doc """
  Resolves the signed-in user from a session map: a Plug session
  (`Plug.Conn.get_session/1`) or a LiveView mount session, both keyed by
  strings.

  Returns `nil` when the session carries no token, or when the token no
  longer maps to a live session row.
  """
  @spec user_from_session(map()) :: UserSchema.t() | nil
  def user_from_session(session), do: Session.get_user_by_token(session["user_token"])

  @doc """
  Remembers an unverified user in the Plug session, so the verify-email page
  can offer to resend their link.

  Only call this once the user has proved who they are: whoever holds this
  session can have the verification email resent, which rotates the pending
  link. `unverified_user_from_session/1` reads it back.
  """
  @spec put_unverified_user(Plug.Conn.t(), %{
          required(:id) => pos_integer(),
          required(:email) => String.t(),
          optional(atom()) => term()
        }) :: Plug.Conn.t()
  def put_unverified_user(conn, %{id: id, email: email}) do
    conn
    |> put_session(:unverified_user_id, id)
    |> put_session(:unverified_user_email, email)
    |> put_session(:unverified_session_timestamp, DateTime.to_unix(DateTime.utc_now()))
  end

  @doc """
  Forgets the unverified user stored by `put_unverified_user/2`.
  """
  @spec clear_unverified_user(Plug.Conn.t()) :: Plug.Conn.t()
  def clear_unverified_user(conn) do
    conn
    |> delete_session(:unverified_user_id)
    |> delete_session(:unverified_user_email)
    |> delete_session(:unverified_session_timestamp)
  end

  @doc """
  The unverified user stored by `put_unverified_user/2`, read from a session
  map, or `nil` when there is none or it is older than thirty minutes.
  """
  @spec unverified_user_from_session(map()) :: unverified_user() | nil
  def unverified_user_from_session(session) do
    with user_id when is_integer(user_id) <- session["unverified_user_id"],
         email when is_binary(email) <- session["unverified_user_email"],
         timestamp when is_integer(timestamp) <- session["unverified_session_timestamp"],
         true <- unverified_fresh?(timestamp) do
      %{id: user_id, email: email, timestamp: timestamp}
    else
      _other -> nil
    end
  end

  defp unverified_fresh?(timestamp),
    do: DateTime.to_unix(DateTime.utc_now()) - timestamp < @unverified_ttl_seconds
end
