defmodule TymeslotWeb.Plugs.TrailingSlashRedirectPlug do
  @moduledoc """
  Permanently redirects `GET`/`HEAD` requests for `/path/` to `/path`.

  The router matches on path segments, so `/docs/` and `/docs` render the same
  page. The canonical link already names the slashless form, but answering the
  slashed one with a 200 still leaves crawlers two URLs for every page; a 301
  collapses them into one. The query string is kept.

  Only safe methods are redirected: a 301 on a form post or a webhook would
  lose its body. A path whose slashless form would begin with `//` or `/\\`
  passes through untouched, because browsers read either as a
  protocol-relative URL and the redirect would leave the site.
  """
  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: method, request_path: path} = conn, _opts)
      when method in ["GET", "HEAD"] and path != "/" do
    with true <- String.ends_with?(path, "/"),
         "/" <> rest = target <- String.trim_trailing(path, "/"),
         false <- String.starts_with?(rest, ["/", "\\"]) do
      conn
      |> put_resp_header("location", target <> query_suffix(conn.query_string))
      |> send_resp(301, "")
      |> halt()
    else
      _no_redirect -> conn
    end
  end

  def call(conn, _opts), do: conn

  defp query_suffix(""), do: ""
  defp query_suffix(query), do: "?" <> query
end
