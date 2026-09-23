defmodule TymeslotWeb.Hooks.AuthLiveSessionHook do
  @moduledoc """
  LiveView `on_mount` hooks that resolve the signed-in user.

    * `:ensure_authenticated` assigns `:current_user` and halts with a redirect
      to the login page when nobody is signed in.
    * `:fetch_current_user` assigns `:current_user`, `nil` when nobody is
      signed in.
    * `{:redirect_if_authenticated, actions}` sends a signed-in user to the
      post-login page when the LiveView mounts on one of `actions`. The login
      and sign-up screens use it; the emailed-link screens that share their
      LiveView (password reset, email verification) stay reachable while
      signed in.

  All of them also assign `:is_email_verified`. On the dead render the user
  already resolved by `TymeslotWeb.Plugs.FetchCurrentUser` is reused, so the
  session token is looked up once per request rather than once per hook.

  ## Usage

  ```elixir
  live_session :authenticated,
    on_mount: {TymeslotWeb.Hooks.AuthLiveSessionHook, :ensure_authenticated} do
    live "/dashboard", DashboardLive
  end
  ```
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.LiveView
  import Phoenix.Component

  alias Tymeslot.Auth.Session
  alias Tymeslot.Infrastructure.Config

  @type hook ::
          :ensure_authenticated | :fetch_current_user | {:redirect_if_authenticated, [atom()]}

  @spec on_mount(hook(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont | :halt, Phoenix.LiveView.Socket.t()}
  def on_mount(hook, params, session, socket)

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket = assign_current_user(socket, session)

    case socket.assigns.current_user do
      nil ->
        {:halt,
         socket
         |> put_flash(:error, unauthenticated_message(session))
         |> redirect(to: login_path())}

      _user ->
        {:cont, socket}
    end
  end

  def on_mount(:fetch_current_user, _params, session, socket) do
    {:cont, assign_current_user(socket, session)}
  end

  def on_mount({:redirect_if_authenticated, actions}, _params, session, socket)
      when is_list(actions) do
    socket = assign_current_user(socket, session)

    if socket.assigns.current_user && socket.assigns[:live_action] in actions do
      {:halt,
       socket
       |> put_flash(:info, dgettext("auth", "You are already logged in."))
       |> redirect(to: Config.success_redirect_path())}
    else
      {:cont, socket}
    end
  end

  defp assign_current_user(socket, session) do
    socket = assign_new(socket, :current_user, fn -> Session.user_from_session(session) end)
    assign(socket, :is_email_verified, email_verified?(socket.assigns.current_user))
  end

  defp email_verified?(%{verified_at: %DateTime{}}), do: true
  defp email_verified?(_user), do: false

  # A token that no longer resolves is an expired or revoked session; no token
  # at all means the visitor never signed in.
  defp unauthenticated_message(%{"user_token" => token}) when is_binary(token),
    do: dgettext("auth", "Your session has expired. Please log in again.")

  defp unauthenticated_message(_session),
    do: dgettext("auth", "You must be logged in to access this page.")

  # The login path lived under OTP app `:auth`, which neither repo configures,
  # so the inline default always won. It belongs in the same `:tymeslot, :auth`
  # keyword list the post-login redirect already reads. Config exposes no
  # public reader for this key (only `success_redirect_path/0`), so the
  # lookup stays here, guarded the same way `Config.success_redirect_path/0`
  # guards its own read.
  defp login_path do
    case Application.get_env(:tymeslot, :auth) do
      config when is_list(config) -> Keyword.get(config, :login_path, "/auth/login")
      _other -> "/auth/login"
    end
  end
end
