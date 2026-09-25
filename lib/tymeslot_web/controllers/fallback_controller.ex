defmodule TymeslotWeb.FallbackController do
  @moduledoc """
  Catch-all for paths that match no route.

  Answers with a real `404 Not Found`; see `TymeslotWeb.NotFound` for why it
  is not a soft-404 redirect and why both layouts are disabled.
  """
  use TymeslotWeb, :controller

  alias TymeslotWeb.NotFound

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params), do: NotFound.render(conn)
end
