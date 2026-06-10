defmodule TymeslotWeb.Components.UserDropdownComponent do
  @moduledoc """
  User dropdown component for the dashboard layout.
  Handles user display name, avatar, and dropdown menu with LiveView state.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Profiles

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns =
      assign(assigns, :display_name, get_display_name(assigns.profile, assigns.current_user))

    assigns = assign(assigns, :truncated_name, truncate_display_name(assigns.display_name))

    ~H"""
    <div>
      <.dropdown
        id="user-menu"
        open={@dropdown_open}
        on_toggle="toggle_user_dropdown"
        on_close="hide_user_dropdown"
        target={@myself}
        trigger_class="flex items-center space-x-3 bg-white border-2 border-tymeslot-50 rounded-2xl px-3 py-2 shadow-sm hover:border-turquoise-100 hover:shadow-md transition-all focus:outline-none focus:ring-2 focus:ring-turquoise-500"
        class="w-56 bg-white rounded-2xl shadow-2xl ring-1 ring-tymeslot-200 border-2 border-tymeslot-50 overflow-hidden"
      >
      <:trigger>
        <div class="w-10 h-10 rounded-xl overflow-hidden bg-tymeslot-100 border-2 border-white shadow-sm flex-shrink-0">
          <img
            src={Profiles.avatar_url(@profile, :thumb)}
            alt={Profiles.avatar_alt_text(@profile)}
            class="w-full h-full object-cover"
          />
        </div>
        <span class="text-tymeslot-800 font-black hidden sm:inline">{@truncated_name}</span>
        <svg
          class={[
            "w-5 h-5 text-tymeslot-400 transition-transform duration-300",
            if(@dropdown_open, do: "rotate-180", else: "")
          ]}
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
        >
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M19 9l-7 7-7-7" />
        </svg>
      </:trigger>
      <:panel>
        <div class="py-2" role="none">
          <.dropdown_item
            label="Account Settings"
            icon="hero-cog-6-tooth"
            phx-click="navigate_and_close"
            phx-value-path="/dashboard/account"
            phx-target={@myself}
          />
          <.dropdown_item
            :if={@current_user.is_admin}
            label="Admin Settings"
            icon="hero-shield-check"
            navigate={~p"/admin"}
            phx-click="hide_user_dropdown"
            phx-target={@myself}
          />
          <.dropdown_divider />
          <.dropdown_item
            label="Sign Out"
            icon="hero-arrow-right-on-rectangle"
            danger={true}
            href={~p"/auth/logout"}
            method="delete"
            phx-click="hide_user_dropdown"
            phx-target={@myself}
          />
        </div>
      </:panel>
      </.dropdown>
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("toggle_user_dropdown", _params, socket) do
    new_state = !socket.assigns.dropdown_open
    {:noreply, assign(socket, :dropdown_open, new_state)}
  end

  def handle_event("hide_user_dropdown", _params, socket) do
    {:noreply, assign(socket, :dropdown_open, false)}
  end

  def handle_event("navigate_and_close", %{"path" => path}, socket) do
    {:noreply,
     socket
     |> assign(:dropdown_open, false)
     |> push_navigate(to: path)}
  end

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok, assign(socket, :dropdown_open, false)}
  end

  # Helper function to get display name (full name or email fallback).
  # All render sites are authenticated, so `current_user` is always present.
  defp get_display_name(profile, current_user) do
    cond do
      profile && profile.full_name && String.trim(profile.full_name) != "" ->
        String.trim(profile.full_name)

      current_user.email ->
        current_user.email

      true ->
        "User"
    end
  end

  # Helper function to truncate display name if too long
  defp truncate_display_name(name) do
    if String.length(name) > 25 do
      String.slice(name, 0, 22) <> "..."
    else
      name
    end
  end
end
