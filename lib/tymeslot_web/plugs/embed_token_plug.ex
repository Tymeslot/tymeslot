defmodule TymeslotWeb.Plugs.EmbedTokenPlug do
  @moduledoc """
  Generates a signed embed token for requests with `?embed=1`.

  The token is stored in `conn.assigns[:embed_token]` and passed to
  LiveView hooks via the router's session function, enabling WebSocket
  connections that work without session cookies.
  """

  @behaviour Plug

  import Plug.Conn

  alias Tymeslot.Embed.Token
  alias TymeslotWeb.Helpers.PathUtils

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    conn = fetch_query_params(conn)

    if conn.query_params["embed"] == "1" do
      case PathUtils.extract_username_from_path(conn.request_path) do
        nil -> conn
        username -> assign(conn, :embed_token, Token.sign(username))
      end
    else
      conn
    end
  end
end
