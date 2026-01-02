defmodule TymeslotWeb.DebugThemeController do
  use TymeslotWeb, :controller

  @spec theme_1(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def theme_1(conn, _params) do
    redirect(conn, to: ~p"/debug/scheduling/theme/1")
  end

  @spec theme_2(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def theme_2(conn, _params) do
    redirect(conn, to: ~p"/debug/scheduling/theme/2")
  end
end
