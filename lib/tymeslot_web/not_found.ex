defmodule TymeslotWeb.NotFound do
  @moduledoc """
  Renders the branded `404 Not Found` page from a controller or a plug.

  Every surface that answers "there is nothing here" goes through `render/1`
  (the catch-all `FallbackController`, the admin-scope plugs, and the SaaS
  overlay's blocked and malformed routes), so the response is identical
  wherever it comes from and a probe cannot tell them apart.

  The response is a real `404` rather than a soft-404 redirect. Bouncing an
  unmatched URL to `/` with a flash produces a `302 → 200` chain that crawlers
  and monitoring read as a valid page; an honest 404 keeps stale and garbage
  URLs out of search indexes and lets clients distinguish "missing" from
  "moved".

  Both layouts are disabled so the self-contained `ErrorHTML` 404 template
  renders on its own. The root layout's `<head>` emits a self-referential
  `<link rel="canonical">`; on a 404 that would advertise the missing URL as its
  own canonical, telling crawlers a dead page is real. The app layout would
  prepend a flash group ahead of the template's `<html>` skeleton. Disabling
  both matches the bare `NoRouteError` path (`render_errors: layout: false`),
  which the branded template is also written to render under.

  Only an HTML view is registered: every caller sits behind a pipeline that
  accepts `html` alone, so no other format can reach it.

  The caller decides whether to halt; a plug must, a controller need not.
  """

  alias Phoenix.Controller
  alias Plug.Conn

  @spec render(Conn.t()) :: Conn.t()
  def render(conn) do
    conn
    |> Conn.put_status(:not_found)
    |> Controller.put_root_layout(html: false)
    |> Controller.put_layout(html: false)
    |> Controller.put_view(html: TymeslotWeb.ErrorHTML)
    |> Controller.render(:"404")
  end
end
