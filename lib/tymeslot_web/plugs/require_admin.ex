defmodule TymeslotWeb.Plugs.RequireAdmin do
  @moduledoc """
  Gates the `/admin` scope.

    * Admin user → request continues.
    * Authenticated non-admin → redirected to `/dashboard` with an explanatory
      flash. The user is signed in and can already see the rest of the app, so
      a 404 would be a worse UX than telling them why they're being bounced.
    * No `current_user` → 404. The router never gets here: the upstream
      `require_authenticated_user` pipeline redirects anonymous visitors to
      the login page first, so the scope's existence is not hidden from them.
      The clause is a fail-closed default for the plug being mounted without
      that pipeline.
  """

  use Phoenix.VerifiedRoutes,
    endpoint: TymeslotWeb.Endpoint,
    router: TymeslotWeb.Router,
    statics: TymeslotWeb.static_paths()

  use Gettext, backend: TymeslotWeb.Gettext

  import Plug.Conn

  alias Phoenix.Controller
  alias Tymeslot.Auth.UserSchema
  alias TymeslotWeb.NotFound

  @spec init(Keyword.t()) :: Keyword.t()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), Keyword.t()) :: Plug.Conn.t()
  def call(%Plug.Conn{assigns: %{current_user: %UserSchema{is_admin: true}}} = conn, _opts) do
    conn
  end

  def call(%Plug.Conn{assigns: %{current_user: %UserSchema{}}} = conn, _opts) do
    conn
    |> Controller.put_flash(:error, dgettext("dashboard_admin", "Admin access required."))
    |> Controller.redirect(to: ~p"/dashboard")
    |> halt()
  end

  def call(conn, _opts) do
    conn
    |> NotFound.render()
    |> halt()
  end
end
