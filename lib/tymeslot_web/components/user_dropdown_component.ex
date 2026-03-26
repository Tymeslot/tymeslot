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
    <div
      class="relative"
      phx-click-away={if @dropdown_open, do: "hide_user_dropdown", else: nil}
      phx-target={@myself}
    >
      <%!-- Dropdown toggle button --%>
      <button
        type="button"
        class="flex items-center space-x-3 bg-white border-2 border-tymeslot-50 rounded-2xl px-3 py-2 shadow-sm hover:border-turquoise-100 hover:shadow-md transition-all focus:outline-none focus:ring-2 focus:ring-turquoise-500"
        phx-click="toggle_user_dropdown"
        phx-target={@myself}
      >
        <%!-- User avatar --%>
        <div class="w-10 h-10 rounded-xl overflow-hidden bg-tymeslot-100 border-2 border-white shadow-sm flex-shrink-0">
          <img
            src={Profiles.avatar_url(@profile, :thumb)}
            alt={Profiles.avatar_alt_text(@profile)}
            class="w-full h-full object-cover"
          />
        </div>
        <%!-- Display name --%>
        <span class="text-tymeslot-800 font-black hidden sm:inline">{@truncated_name}</span>
        <%!-- Dropdown arrow --%>
        <svg
          class={[
            "w-5 h-5 text-tymeslot-400 transition-transform duration-300",
            if(@dropdown_open, do: "rotate-180", else: "")
          ]}
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
        >
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M19 9l-7 7-7-7">
          </path>
        </svg>
      </button>
      
    <%!-- Dropdown menu --%>
      <div
        class={[
          "absolute right-0 mt-3 w-56 bg-white rounded-2xl shadow-2xl ring-1 ring-tymeslot-200 focus:outline-none border-2 border-tymeslot-50 overflow-hidden z-[100]",
          if(@dropdown_open, do: "block animate-in fade-in zoom-in duration-200", else: "hidden")
        ]}
        role="menu"
        aria-orientation="vertical"
      >
        <div class="py-2" role="none">
          <%!-- Account Settings --%>
          <div
            phx-click="navigate_and_close"
            phx-value-path="/dashboard/account"
            phx-target={@myself}
            class="group flex items-center px-4 py-3 text-sm font-bold text-tymeslot-700 hover:bg-turquoise-50 hover:text-turquoise-700 transition-colors cursor-pointer"
            role="menuitem"
          >
            <div class="w-8 h-8 rounded-lg bg-tymeslot-50 flex items-center justify-center mr-3 group-hover:bg-white transition-colors shadow-sm">
              <svg
                class="h-4 w-4 text-tymeslot-400 group-hover:text-turquoise-600"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2.5"
                  d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"
                >
                </path>
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2.5"
                  d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
                >
                </path>
              </svg>
            </div>
            Account Settings
          </div>
          
    <%!-- Divider --%>
          <div class="border-t-2 border-tymeslot-50 my-1"></div>
          
    <%!-- Sign Out --%>
          <.link
            href={~p"/auth/logout"}
            method="delete"
            class="group flex items-center px-4 py-3 text-sm font-bold text-red-600 hover:bg-red-50 hover:text-red-700 transition-colors"
            role="menuitem"
            phx-click="hide_user_dropdown"
            phx-target={@myself}
          >
            <div class="w-8 h-8 rounded-lg bg-red-50 flex items-center justify-center mr-3 transition-colors shadow-sm">
              <svg
                class="h-4 w-4 text-red-400"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2.5"
                  d="M17 16l4-4m0 0l-4-4m4 4H7m6 4v1a3 3 0 01-3 3H6a3 3 0 01-3-3V7a3 3 0 013-3h4a3 3 0 013 3v1"
                >
                </path>
              </svg>
            </div>
            Sign Out
          </.link>
        </div>
      </div>
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

  # Helper function to get display name (full name or email fallback)
  defp get_display_name(profile, current_user) do
    cond do
      profile && profile.full_name && String.trim(profile.full_name) != "" ->
        String.trim(profile.full_name)

      current_user && current_user.email ->
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
