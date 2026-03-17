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
        nil ->
          conn

        username ->
          parent_origin = resolve_parent_origin(conn)
          assign(conn, :embed_token, Token.sign(username, parent_origin))
      end
    else
      conn
    end
  end

  # Prefer the browser-enforced Referer header over the client-supplied
  # query parameter. The Referer is set by the browser when loading an
  # iframe and cannot be spoofed by JavaScript, making it a stronger
  # signal for the embedding page's origin.
  #
  # Falls back to the query parameter when Referer is absent (e.g. due
  # to Referrer-Policy: no-referrer on the embedding page).
  defp resolve_parent_origin(conn) do
    referer_origin(conn) || conn.query_params["parent-origin"]
  end

  defp referer_origin(conn) do
    with [referer | _rest] <- get_req_header(conn, "referer"),
         %URI{scheme: scheme, host: host}
         when is_binary(scheme) and is_binary(host) <- URI.parse(referer) do
      "#{scheme}://#{host}"
    else
      _no_referer -> nil
    end
  end
end
