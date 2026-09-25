defmodule TymeslotWeb.Plugs.FetchCurrentUser do
  @moduledoc """
  Resolves the signed-in user from the session and assigns it to the
  connection as `:current_user` (`nil` when nobody is signed in).

  A session token that no longer maps to a live session (expired or revoked)
  is dropped from the session, so the browser stops presenting it on every
  later request.

  Runs in the browser pipelines so the user is available to every controller
  and to the dead render of every LiveView.
  """

  import Plug.Conn

  alias TymeslotWeb.UserAuth

  @spec init(Keyword.t()) :: Keyword.t()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), Keyword.t()) :: Plug.Conn.t()
  def call(conn, _opts) do
    session = get_session(conn)
    user = UserAuth.user_from_session(session)

    conn
    |> drop_dead_token(session, user)
    |> assign(:current_user, user)
  end

  defp drop_dead_token(conn, %{"user_token" => _token}, nil) do
    conn
    |> delete_session(:user_token)
    |> delete_session(:live_socket_id)
  end

  defp drop_dead_token(conn, _session, _user), do: conn
end
