defmodule TymeslotWeb.Dev.EmbedTestController do
  @moduledoc """
  Dev-only controller that serves an interactive embed test page at
  `/dev/embed-test`.

  The page renders four embed scenarios side-by-side (unconstrained, constrained,
  small fixed height, popup) and lets you switch usernames and themes on the fly.
  It loads `/embed.js` from the running dev server, so `mix phx.server` must be
  running.

  ## Testing with an external HTML file

  If you want to test embedding from a standalone HTML file, you must **serve it
  over HTTP** rather than opening it directly as a `file://` URL. Opening as
  `file://` gives the page a `null` origin, which is not covered by the dev CSP
  `frame-ancestors` allowlist (`http://localhost:* http://127.0.0.1:*`), so the
  iframe is blocked.

  A sample page lives at `/tmp/tymeslot-embed-test.html` and covers three
  `data-min-height` scenarios: default (400px), explicit 600px, and the 200px
  floor. Use it to validate the attribute end-to-end.

  Serve it from a local HTTP server:

      python3 -m http.server 8080 -d /tmp

  Then open `http://localhost:8080/tymeslot-embed-test.html` in your browser. The
  page origin matches `http://localhost:*` in the CSP and the embed works as
  expected.
  """
  use TymeslotWeb, :controller

  alias TymeslotWeb.Endpoint

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    conn
    |> put_root_layout(false)
    |> put_layout(false)
    |> render(:index,
      username: params["username"] || "demo",
      base_url: Endpoint.url(),
      nonce: conn.assigns[:csp_nonce]
    )
  end
end
