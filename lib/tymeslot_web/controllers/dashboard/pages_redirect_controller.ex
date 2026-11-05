defmodule TymeslotWeb.Dashboard.PagesRedirectController do
  @moduledoc """
  Forwards the Theme screen's old addresses to the booking pages screen that
  replaced it, keeping the query string, so a selected page (`?page=<id>`)
  survives the move.
  """
  use TymeslotWeb, :controller

  @spec pages(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def pages(conn, _params), do: forward(conn, ~p"/dashboard/pages")

  @spec customize(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def customize(conn, %{"theme_id" => theme_id}),
    do: forward(conn, ~p"/dashboard/pages/customize/#{theme_id}")

  defp forward(%Plug.Conn{query_string: ""} = conn, path), do: redirect(conn, to: path)
  defp forward(conn, path), do: redirect(conn, to: path <> "?" <> conn.query_string)
end
