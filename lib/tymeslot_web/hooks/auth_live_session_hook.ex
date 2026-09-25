defmodule TymeslotWeb.Hooks.AuthLiveSessionHook do
  @moduledoc """
  LiveView `on_mount` hooks that resolve the signed-in user.

    * `:ensure_authenticated` assigns `:current_user` and halts with a redirect
      to the login page when nobody is signed in.
    * `:fetch_current_user` assigns `:current_user`, `nil` when nobody is
      signed in.
    * `{:redirect_if_authenticated, actions: actions, events: events}` sends a
      signed-in user to the post-login page when the LiveView mounts or is
      patched onto one of `actions`, and refuses the listed `events`. The
      login and sign-up screens use it; the emailed-link screens that share
      their LiveView (password reset, email verification) stay reachable
      while signed in.

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

  alias Tymeslot.Infrastructure.Config
  alias TymeslotWeb.UserAuth

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

  def on_mount({:redirect_if_authenticated, opts}, _params, session, socket) when is_list(opts) do
    actions = Keyword.fetch!(opts, :actions)
    events = Keyword.get(opts, :events, [])
    socket = assign_current_user(socket, session)

    cond do
      is_nil(socket.assigns.current_user) ->
        {:cont, socket}

      socket.assigns[:live_action] in actions ->
        {:halt, send_signed_in_user_on(socket)}

      true ->
        # A LiveView that switches screens with push_patch never mounts again,
        # so the same check has to run on every patch, and the listed events
        # (a sign-up submission, say) are refused whichever screen sent them.
        {:cont,
         socket
         |> attach_hook(:redirect_if_authenticated_params, :handle_params, fn _params,
                                                                              _uri,
                                                                              socket ->
           if socket.assigns[:live_action] in actions,
             do: {:halt, send_signed_in_user_on(socket)},
             else: {:cont, socket}
         end)
         |> attach_hook(:redirect_if_authenticated_events, :handle_event, fn event,
                                                                             _params,
                                                                             socket ->
           if event in events,
             do: {:halt, send_signed_in_user_on(socket)},
             else: {:cont, socket}
         end)}
    end
  end

  defp send_signed_in_user_on(socket) do
    socket
    |> put_flash(:info, dgettext("auth", "You are already logged in."))
    |> redirect(to: Config.success_redirect_path())
  end

  defp assign_current_user(socket, session) do
    socket = assign_new(socket, :current_user, fn -> UserAuth.user_from_session(session) end)
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
