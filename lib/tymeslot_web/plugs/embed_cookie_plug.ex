defmodule TymeslotWeb.Plugs.EmbedCookiePlug do
  @moduledoc """
  Rewrites the session cookie to `SameSite=None; Secure` when the response is
  for a page that allows cross-site embedding.

  Browsers reject `SameSite=Lax` cookies in cross-site iframe contexts, which
  breaks LiveView's WebSocket session handshake and causes a reconnect loop.

  Must be plugged **before** `Plug.Session` in the endpoint so that its
  `before_send` callback fires **after** `Plug.Session` has written the cookie
  (callbacks registered earlier run later in `Enum.reduce`).

  The flag `conn.private[:embed_cookie_samesite_none]` is set by
  `SecurityHeadersPlug` when the profile allows cross-site embedding.
  """

  import Plug.Conn

  @session_cookie "_tymeslot_key"

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    register_before_send(conn, fn conn ->
      if conn.private[:embed_cookie_samesite_none] do
        rewrite_session_cookie(conn)
      else
        conn
      end
    end)
  end

  defp rewrite_session_cookie(conn) do
    case conn.resp_cookies do
      %{@session_cookie => %{secure: true} = cookie} ->
        updated = Map.put(cookie, :same_site, "None")
        %{conn | resp_cookies: Map.put(conn.resp_cookies, @session_cookie, updated)}

      _no_secure_cookie ->
        # SameSite=None requires Secure; skip rewrite in dev/test (http)
        conn
    end
  end
end
