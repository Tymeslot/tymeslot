defmodule TymeslotWeb.FallbackController do
  use TymeslotWeb, :controller

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    redirect(conn, to: ~p"/")
  end
end
