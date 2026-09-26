defmodule TymeslotWeb.Plugs.WebhookBodyCachePlug do
  @moduledoc """
  A `:body_reader` for `Plug.Parsers` that keeps the raw request body of
  signed webhooks in `conn.assigns.raw_body`.

  Signature verification has to run over the byte-exact body, which
  `Plug.Parsers` consumes before any controller or pipeline plug sees it.

  Which requests get their body cached is read off the router rather than
  kept in a separate list: a route opts in with `metadata: %{raw_body: true}`.
  The list used to live in config beside the router and had to be kept in
  step by hand; a route missing from it had its signature checked against an
  empty body and every genuine delivery was refused.

  The lookup is a runtime route match rather than a list gathered at compile
  time: the endpoint depends on this module at compile time, and a
  compile-time dependency on the router would make the endpoint recompile
  whenever anything the router reaches changes.
  """

  require Logger
  alias Phoenix.Router
  alias Plug.Conn

  # Named without a literal alias for the same reason: xref records the
  # endpoint's compile-time edge to this module as compile-connected to
  # everything a literal router reference pulls in, although this module only
  # ever calls the router at request time.
  @router Module.concat(["TymeslotWeb", "Router"])

  @doc """
  Custom body reader that caches the raw body for webhook paths.
  This should be used in Plug.Parsers configuration.
  """
  @spec read_body(Plug.Conn.t(), keyword()) :: {:ok, binary(), Plug.Conn.t()} | {:error, any()}
  def read_body(conn, opts) do
    case Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        conn = maybe_cache_body(conn, body)
        {:ok, body, conn}

      other ->
        other
    end
  end

  defp maybe_cache_body(conn, body) do
    if raw_body_route?(conn) do
      Logger.debug("WebhookBodyCachePlug: Caching raw body", path: conn.request_path)
      Conn.assign(conn, :raw_body, body)
    else
      conn
    end
  end

  defp raw_body_route?(conn) do
    case Router.route_info(@router, conn.method, conn.path_info, conn.host) do
      %{raw_body: true} -> true
      _no_route_or_not_signed -> false
    end
  end
end
