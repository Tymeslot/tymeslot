defmodule TymeslotWeb.Plugs.RequireAdmin do
  @moduledoc """
  Gates the `/admin` scope.

    * Admin user → request continues.
    * Authenticated non-admin → redirected to `/dashboard` with an explanatory
      flash. The user is signed in and can already see the rest of the app, so
      a 404 would be a worse UX than telling them why they're being bounced.
    * No `current_user` (defensive — the upstream `require_authenticated_user`
      plug should already have caught this) → 404, so anonymous probes can't
      tell whether the admin scope exists.
  """

  use Phoenix.VerifiedRoutes,
    endpoint: TymeslotWeb.Endpoint,
    router: TymeslotWeb.Router,
    statics: TymeslotWeb.static_paths()

  import Plug.Conn

  alias Phoenix.Controller
  alias Tymeslot.Auth.UserSchema

  @spec init(Keyword.t()) :: Keyword.t()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), Keyword.t()) :: Plug.Conn.t()
  def call(%Plug.Conn{assigns: %{current_user: %UserSchema{is_admin: true}}} = conn, _opts) do
    conn
  end

  def call(%Plug.Conn{assigns: %{current_user: %UserSchema{}}} = conn, _opts) do
    conn
    |> Controller.put_flash(:error, "Admin access required.")
    |> Controller.redirect(to: ~p"/dashboard")
    |> halt()
  end

  def call(conn, _opts) do
    conn
    |> put_status(:not_found)
    |> Controller.put_view(html: TymeslotWeb.ErrorHTML, json: TymeslotWeb.ErrorJSON)
    |> Controller.render(:"404")
    |> halt()
  end
end
