defmodule TymeslotWeb.Plugs.FetchCurrentUser do
  @moduledoc """
  A plug that fetches the current user from the session and assigns it to the connection.

  This plug should be used in the browser pipeline to make the current user
  available in all controllers and views.
  """

  import Plug.Conn
  alias Tymeslot.Auth.Authentication

  @spec init(Keyword.t()) :: Keyword.t()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), Keyword.t()) :: Plug.Conn.t()
  def call(conn, _opts) do
    user_token = get_session(conn, :user_token)

    user = user_token && Authentication.get_user_by_session_token(user_token)

    conn
    |> assign(:current_user, user)
    |> assign(:user_token, user_token)
  end
end
