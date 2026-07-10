defmodule TymeslotWeb.Plugs.RequireAuthPlug do
  @moduledoc """
  Demo plug to require authentication.
  """
  use Phoenix.VerifiedRoutes,
    endpoint: TymeslotWeb.Endpoint,
    router: TymeslotWeb.Router,
    statics: TymeslotWeb.static_paths()

  use Gettext, backend: TymeslotWeb.Gettext

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
      |> Controller.put_flash(
        :error,
        dgettext("auth", "You must be logged in to access this page.")
      )
      |> Controller.redirect(to: ~p"/auth/login")
      |> halt()
    end
  end
end
