defmodule TymeslotWeb.Plugs.ForgeryProtection do
  @moduledoc """
  `protect_from_forgery/2` for the router pipelines: Phoenix's CSRF check,
  with a recoverable answer to a stale token instead of a bare 403.

  A form carries the CSRF token of the session it was rendered under. Signing
  out (in any tab) or losing the session cookie replaces that session, so a
  page left open since then posts a token the server no longer accepts. That
  is far more often a stale tab than a forgery, and both deserve the same
  harmless answer: nothing is done, and the visitor is sent back to the page
  the form came from (or the home page, when the request did not come from
  this site), where a fresh render carries a valid token, with a flash asking
  them to try again.

  The router imports this function in place of
  `Phoenix.Controller.protect_from_forgery/2`, so pipelines keep reading
  `plug :protect_from_forgery`, and the check itself is still
  `Plug.CSRFProtection`'s.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Phoenix.Controller
  alias Plug.Conn
  alias Plug.CSRFProtection.InvalidCSRFTokenError

  @spec protect_from_forgery(Conn.t(), keyword()) :: Conn.t()
  def protect_from_forgery(conn, opts \\ []) do
    Controller.protect_from_forgery(conn, opts)
  rescue
    InvalidCSRFTokenError ->
      Logger.info("Rejected a request with a stale or missing CSRF token",
        method: conn.method,
        path: conn.request_path
      )

      send_back_to_retry(conn)
  end

  defp send_back_to_retry(conn) do
    conn
    |> Controller.put_flash(
      :error,
      dgettext("common", "Your session has changed since this page was opened. Please try again.")
    )
    |> Controller.redirect(to: return_path(conn))
    |> Conn.halt()
  end

  # The path the form was submitted from, when the browser says it was this
  # site; otherwise the home page. Only the path and query are kept, and a
  # path that a browser would read as another host (`//evil.com`, `/\evil.com`)
  # is refused, so the redirect can never leave the site.
  defp return_path(conn) do
    with [referer | _other] <- Conn.get_req_header(conn, "referer"),
         %URI{host: host, path: "/" <> rest = path} = uri when host == conn.host <-
           URI.parse(referer),
         false <- String.starts_with?(rest, ["/", "\\"]) do
      if uri.query, do: path <> "?" <> uri.query, else: path
    else
      _no_local_referer -> "/"
    end
  end
end
