defmodule TymeslotWeb.E2E.HostSite do
  @moduledoc """
  An embedder's website for browser tests of the embed loader: a server of
  its own on 127.0.0.1 and a free port, so the booking page is framed from
  another site, through the embed token, the embed socket and the allowlist
  check on the parent origin, as on a customer's page.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 2]

  alias Plug.Conn
  alias TymeslotWeb.Endpoint

  @doc """
  Serves `pages` (request path => HTML) until the test ends and returns the
  site's origin. Call it from the test process.
  """
  @spec start!(%{String.t() => String.t()}) :: String.t()
  def start!(pages) do
    plug = fn conn, _opts ->
      case Map.fetch(pages, conn.request_path) do
        {:ok, html} ->
          conn
          |> Conn.put_resp_content_type("text/html")
          |> Conn.send_resp(200, html)

        :error ->
          Conn.send_resp(conn, 404, "")
      end
    end

    server =
      start_supervised!(
        {Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: {:host_site, make_ref()}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end

  @doc """
  A host page holding `body`, then the app's `embed.js`, then `after_loader`
  (a script that calls the loader, say).
  """
  @spec page(String.t(), String.t()) :: String.t()
  def page(body, after_loader \\ "") do
    """
    <!doctype html>
    <html lang="en">
      <head><meta charset="utf-8"><title>Host site</title></head>
      <body style="margin: 0; font-family: sans-serif">
        <h1 id="top">An embedder's site</h1>
        #{body}
        <script src="#{Endpoint.url()}/embed.js"></script>
        #{after_loader}
      </body>
    </html>
    """
  end
end
