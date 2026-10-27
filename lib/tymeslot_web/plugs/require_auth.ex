defmodule TymeslotWeb.Plugs.RequireAuthPlug do
  @moduledoc """
  Requires a signed-in user: the `:require_authenticated_user` pipeline.

  Reads the `:current_user` assigned by `TymeslotWeb.Plugs.FetchCurrentUser`,
  which must run first, and redirects anyone without one to the login page
  with an explanatory flash. LiveViews behind this plug re-check on mount with
  `{TymeslotWeb.Hooks.AuthLiveSessionHook, :ensure_authenticated}`, since a
  live navigation does not pass through the plug pipeline.

  A GET names the page it asked for in the login link (see
  `TymeslotWeb.Plugs.ReturnTo`), so signing in ends there; any other method
  is a form submitted from a page that has gone, and goes to the plain login.

  An account pending deletion is frozen: it is sent to `/auth/restore`
  instead, the one signed-in page it can reach.
  """
  use Phoenix.VerifiedRoutes,
    endpoint: TymeslotWeb.Endpoint,
    router: TymeslotWeb.Router,
    statics: TymeslotWeb.static_paths()

  use Gettext, backend: TymeslotWeb.Gettext

  import Plug.Conn

  alias Phoenix.Controller
  alias Tymeslot.Auth
  alias TymeslotWeb.Plugs.ReturnTo

  @spec init(any()) :: any()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), any()) :: Plug.Conn.t()
  def call(conn, _opts) do
    case conn.assigns[:current_user] do
      nil ->
        conn
        |> Controller.put_flash(
          :error,
          dgettext("auth", "You must be logged in to access this page.")
        )
        |> Controller.redirect(to: login_path(conn))
        |> halt()

      user ->
        if Auth.deletion_pending?(user),
          do: conn |> Controller.redirect(to: ~p"/auth/restore") |> halt(),
          else: conn
    end
  end

  defp login_path(%Plug.Conn{method: "GET"} = conn),
    do: conn |> ReturnTo.requested_path() |> ReturnTo.login_path()

  defp login_path(_conn), do: ~p"/auth/login"
end
