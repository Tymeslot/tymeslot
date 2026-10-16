defmodule TymeslotWeb.Plugs.EmbedTokenPlug do
  @moduledoc """
  Generates a signed embed token for framed requests with `?embed=1`.

  The token is stored in `conn.assigns[:embed_token]` and passed to
  LiveView hooks via the router's session function, enabling WebSocket
  connections that work without session cookies.

  No session cookie is written back for embed requests: the browser would
  reject it anyway (SameSite=Lax in a cross-site iframe), and auth for
  embedded pages is handled entirely by the embed token.

  That is `ignore: true`, never `drop: true`. The two read alike and are
  opposites: `:ignore` discards the *outgoing* write and leaves the request's
  cookie untouched, while `:drop` deletes the cookie the caller already has.
  Because the booking page is public and same-origin with the dashboard, the
  live preview's iframe sends the organiser's session cookie with the request,
  so `:drop` answered it with a site-wide `Set-Cookie: _tymeslot_key=;
  expires=1970; path=/` and logged the organiser out of their own dashboard on
  the next navigation (issue #96).

  A request the browser marks `Sec-Fetch-Dest: document` is a top-level
  visit (the embed URL copied into its own tab), not a frame, so `embed=1` is
  ignored and it is served as an ordinary page. Treating it as an embed wrote
  no session, and the unframed page then connected to the session socket
  without one and reloaded itself for ever. A framed request sends `iframe`;
  a request without the header keeps the embed behaviour, as before. Every
  `embed=1` response carries `Vary: Sec-Fetch-Dest`, since its treatment
  depends on the header.

  Browsers send `Sec-Fetch-Dest` only to secure origins (and Safari only
  since 16.4), so a top-level visit over plain HTTP or from an older browser
  still arrives without it and is served as an embed; the server cannot tell
  it from a frame. The root layout marks every page served as an embed
  (`data-embed-served` on `<html>`, set when this plug assigned an embed
  token), and the page itself decides: framed, it connects to the
  session-free embed socket; not framed, it replaces itself with the same URL
  minus `embed` and `parent-origin` (`topLevelEmbedRedirect` in
  `assets/js/live_socket_path.js`), which this plug serves as an ordinary page.

  The session write is skipped exactly when a token is assigned, so the two
  cannot disagree: an `embed=1` path that names no organiser gets neither the
  embed treatment nor the marker, and keeps its session.
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
      conn
      # How an embed URL is served depends on Sec-Fetch-Dest, so a cache must
      # not answer a framed request with a top-level response or the reverse.
      |> prepend_resp_headers([{"vary", "sec-fetch-dest"}])
      |> maybe_serve_as_embed()
    else
      conn
    end
  end

  defp maybe_serve_as_embed(conn) do
    if framed_or_unknown?(conn) do
      case PathUtils.extract_username_from_path(conn.request_path) do
        nil ->
          conn

        username ->
          # Write no session cookie for embed requests: the browser would
          # reject it (SameSite=Lax in a cross-site iframe). `:ignore` drops
          # the write only; `:drop` would delete the cookie the caller sent us.
          # See the moduledoc.
          conn
          |> configure_session(ignore: true)
          |> assign(:embed_token, Token.sign(username, resolve_parent_origin(conn)))
      end
    else
      conn
    end
  end

  defp framed_or_unknown?(conn), do: get_req_header(conn, "sec-fetch-dest") != ["document"]

  # Prefer the browser-enforced Referer header over the client-supplied
  # query parameter. The Referer is set by the browser when loading an
  # iframe and cannot be spoofed by JavaScript, making it a stronger
  # signal for the embedding page's origin.
  #
  # Falls back to the query parameter when Referer is absent (e.g. due
  # to Referrer-Policy: no-referrer on the embedding page), and when the
  # Referer is this site itself. The second case is a navigation the framed
  # page made on its own (the language switcher's redirect): the browser then
  # reports the booking page, not the embedder, so the Referer says nothing
  # about who frames it, and trusting it would fail the allowlist check. That
  # fallback is no weaker than the first, which any embedder can already reach
  # by stripping its Referer; `frame-ancestors` stays the real enforcement.
  defp resolve_parent_origin(conn) do
    case referer_origin(conn) do
      {:own_site, origin} -> conn.query_params["parent-origin"] || origin
      {:external, origin} -> origin
      nil -> conn.query_params["parent-origin"]
    end
  end

  defp referer_origin(conn) do
    with [referer | _rest] <- get_req_header(conn, "referer"),
         %URI{scheme: scheme, host: host, port: port}
         when is_binary(scheme) and is_binary(host) <- URI.parse(referer) do
      origin = origin(scheme, host, port)
      if host == conn.host, do: {:own_site, origin}, else: {:external, origin}
    else
      _no_referer -> nil
    end
  end

  # Keeps a non-default port, so the origin names the page that framed us
  # exactly (`http://localhost:4000`, not `http://localhost`).
  defp origin(scheme, host, port) do
    if port in [nil, URI.default_port(scheme)],
      do: "#{scheme}://#{host}",
      else: "#{scheme}://#{host}:#{port}"
  end
end
