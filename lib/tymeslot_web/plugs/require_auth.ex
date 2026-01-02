defmodule TymeslotWeb.Plugs.RequireAuthPlug do
  @moduledoc """
  Demo plug to require authentication.
  """
  import Plug.Conn

  alias Phoenix.Controller

  @spec init(any()) :: any()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), any()) :: Plug.Conn.t()
  def call(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> Controller.put_flash(:error, "You must be logged in to access this page.")
      |> Controller.redirect(to: "/auth/login")
      |> halt()
    end
  end
end
