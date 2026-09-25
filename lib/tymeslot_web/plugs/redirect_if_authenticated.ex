defmodule TymeslotWeb.Plugs.RedirectIfAuthenticated do
  @moduledoc """
  Sends an already signed-in user to the post-login page instead of letting
  the request through.

  Guards the password login endpoint: signing in a second time on top of a
  live session has nothing to offer and would only mint another token. The
  LiveView login and sign-up screens are guarded by the matching
  `{:redirect_if_authenticated, actions}` hook in
  `TymeslotWeb.Hooks.AuthLiveSessionHook`.

  Relies on `TymeslotWeb.Plugs.FetchCurrentUser` having run first.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Plug.Conn

  alias Phoenix.Controller
  alias Tymeslot.Infrastructure.Config

  @spec init(Keyword.t()) :: Keyword.t()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), Keyword.t()) :: Plug.Conn.t()
  def call(%Plug.Conn{assigns: %{current_user: %{id: _id}}} = conn, _opts) do
    conn
    |> Controller.put_flash(:info, dgettext("auth", "You are already logged in."))
    |> Controller.redirect(to: Config.success_redirect_path())
    |> halt()
  end

  def call(conn, _opts), do: conn
end
