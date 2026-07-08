defmodule TymeslotWeb.Hooks.EnsureAdminHook do
  @moduledoc """
  LiveView on_mount hook that halts and redirects when the current user is
  not an admin. Pairs with `TymeslotWeb.Plugs.RequireAdmin` on the static
  request path so both initial render and live-socket mount enforce admin
  status.

  Assumes `:current_user` has already been assigned by an earlier hook
  (typically `AuthLiveSessionHook.ensure_authenticated`). If the assign is
  missing, treat that as "not admin" — defence in depth.

  In addition to the mount-time check, a per-event hook re-fetches the user
  from the database on every `handle_event` *and* `handle_params` call. This
  ensures that a session whose admin status was revoked in another session
  cannot continue to perform privileged operations — nor re-read admin data
  via a `live_patch` between tabs — on the already-connected socket.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias Tymeslot.Auth
  alias Tymeslot.Auth.UserSchema

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont | :halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, _session, socket) do
    case socket.assigns[:current_user] do
      %UserSchema{is_admin: true} ->
        socket =
          socket
          |> attach_hook(:ensure_admin_per_event, :handle_event, &reauthorize/3)
          |> attach_hook(:ensure_admin_per_params, :handle_params, &reauthorize/3)

        {:cont, socket}

      _other ->
        {:halt, redirect(socket, to: "/dashboard")}
    end
  end

  # Shared by both the `:handle_event` and `:handle_params` hooks. The first
  # two positional arguments differ between the two lifecycle stages
  # (event/params vs params/uri) but are irrelevant here — both ignore them
  # and re-check admin status against the database.
  defp reauthorize(_arg1, _arg2, socket) do
    user_id = socket.assigns.current_user.id

    case Auth.get_user(user_id) do
      {:ok, %UserSchema{is_admin: true} = user} ->
        {:cont, assign(socket, :current_user, user)}

      _other ->
        socket =
          socket
          |> put_flash(:error, dgettext("dashboard_admin", "Your admin access has been revoked."))
          |> push_navigate(to: "/dashboard")

        {:halt, socket}
    end
  end
end
