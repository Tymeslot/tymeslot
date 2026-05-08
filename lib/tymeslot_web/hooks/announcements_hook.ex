defmodule TymeslotWeb.Hooks.AnnouncementsHook do
  @moduledoc """
  Loads unseen feature announcements for the current user and assigns them
  on the socket as `:unseen_announcements`. Pulled in last in the dashboard
  `on_mount` chain — every higher-priority gate (auth, onboarding, legal
  acceptance) runs first.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1]

  alias Tymeslot.Announcements

  @spec on_mount(:load_unseen_announcements, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:load_unseen_announcements, _params, _session, socket) do
    user = socket.assigns[:current_user]

    cond do
      not connected?(socket) -> {:cont, assign(socket, :unseen_announcements, [])}
      is_nil(user) -> {:cont, assign(socket, :unseen_announcements, [])}
      true -> {:cont, assign(socket, :unseen_announcements, Announcements.list_for(user))}
    end
  end
end
