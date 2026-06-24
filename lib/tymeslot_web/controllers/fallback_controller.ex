defmodule TymeslotWeb.FallbackController do
  @moduledoc """
  Catch-all for paths that match no route.

  Returns a real `404 Not Found` instead of a soft-404 redirect. Previously an
  unmatched URL was bounced to `/` (or to a resolved profile) with a flash,
  producing a `302 → 200` chain that crawlers and monitoring read as a valid
  page. Honest 404s keep stale/garbage URLs out of search indexes and let
  clients distinguish "missing" from "moved".
  """
  use TymeslotWeb, :controller

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    conn
    |> put_status(:not_found)
    |> put_view(html: TymeslotWeb.ErrorHTML, json: TymeslotWeb.ErrorJSON)
    |> render(:"404")
  end
end
