defmodule TymeslotWeb.Plugs.CaptureReferrerPlug do
  @moduledoc """
  Captures the external HTTP `Referer` header on the initial document GET
  for public scheduling routes and stores it in the session under
  `"scheduling_referrer"` using first-touch semantics.

  ## Why not the WebSocket upgrade referer?

  When a browser opens a LiveView page the WS upgrade request carries a
  `Referer` that points at the scheduling page itself (same-origin), not
  at the external site that sent the visitor. Reading the referer from
  `connect_info(:x_headers)` in an `on_mount` hook therefore records the
  scheduling-page URL as the referrer host, which is useless for
  attribution.

  This plug runs on the initial HTTP GET — before the page is loaded and
  before the WS connection is established — where the `Referer` header
  still reflects the actual external source. The captured value is
  forwarded to the LiveView through the session (via
  `TymeslotWeb.Router.scheduling_session/1`) so the `on_mount` hook and
  `assign_tracking/2` can pick it up without touching socket headers.

  ## First-touch semantics

  The session key is set only when absent. Internal navigation within the
  scheduling flow (e.g. schedule → booking) issues GET requests too, but
  those already have the key set, so later same-origin pages cannot
  overwrite the original external source.

  ## Same-origin filtering

  Referrers whose host matches the request host are skipped — they come
  from within the application and carry no attribution information. Empty
  or unparseable referrers are also skipped, leaving the session key
  absent (which downstream code interprets as "no referrer").
  """

  import Plug.Conn

  @session_key "scheduling_referrer"

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    if conn.method == "GET" && get_session(conn, @session_key) == nil do
      case cross_origin_referrer(conn) do
        nil -> conn
        referrer -> put_session(conn, @session_key, referrer)
      end
    else
      conn
    end
  end

  # Returns the raw referrer string only when it is cross-origin relative
  # to the current request host, and nil otherwise.
  defp cross_origin_referrer(conn) do
    conn
    |> get_req_header("referer")
    |> List.first()
    |> parse_host()
    |> then(fn referrer_host ->
      if referrer_host && referrer_host != request_host(conn) do
        List.first(get_req_header(conn, "referer"))
      end
    end)
  end

  defp parse_host(nil), do: nil

  defp parse_host(referrer) when is_binary(referrer) do
    case URI.parse(referrer) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _other -> nil
    end
  end

  defp request_host(conn) do
    case get_req_header(conn, "host") do
      [host | _rest] -> host |> String.split(":") |> List.first()
      [] -> conn.host
    end
  end
end
