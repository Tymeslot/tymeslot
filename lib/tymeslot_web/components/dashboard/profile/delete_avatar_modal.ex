defmodule TymeslotWeb.Components.Dashboard.Profile.DeleteAvatarModal do
  @moduledoc """
  Modal for confirming avatar deletion.
  Implemented as a LiveComponent to handle its own state and deletion logic.
  """

  use TymeslotWeb, :live_component

  alias Phoenix.LiveView.JS
  alias Tymeslot.Profiles
  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Live.Shared.Flash

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok, assign(socket, :show, false)}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("show", _params, socket) do
    {:noreply, assign(socket, :show, true)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("hide", _params, socket) do
    {:noreply, assign(socket, :show, false)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("confirm", _params, socket) do
    profile = socket.assigns.profile

    case Profiles.delete_avatar(profile) do
      {:ok, updated_profile} ->
        # Notify the parent LiveView to refresh the profile
        send(self(), {:profile_updated, updated_profile})

        Flash.info("Avatar deleted successfully")

        {:noreply, assign(socket, :show, false)}

      {:error, reason} ->
        Flash.error("Failed to delete avatar: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <CoreComponents.modal
        id={"#{@id}-modal"}
        show={@show}
        on_cancel={JS.push("hide", target: @myself)}
        size={:medium}
      >
        <:header>
          <div class="flex items-center gap-3">
            <div class="w-10 h-10 bg-red-50 rounded-token-xl flex items-center justify-center border border-red-100">
              <svg class="w-6 h-6 text-red-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2.5"
                  d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
                />
              </svg>
            </div>
            <span class="text-2xl font-black text-tymeslot-900 tracking-tight">Delete Avatar</span>
          </div>
        </:header>
        <p class="text-tymeslot-600 font-medium text-lg leading-relaxed">
          Are you sure you want to delete your profile picture? This action cannot be undone.
        </p>
        <:footer>
          <div class="flex justify-end gap-3">
            <CoreComponents.action_button
              variant={:secondary}
              phx-click={JS.push("hide", target: @myself)}
            >
              Cancel
            </CoreComponents.action_button>
            <CoreComponents.action_button
              variant={:danger}
              phx-click={JS.push("confirm", target: @myself)}
            >
              Delete Avatar
            </CoreComponents.action_button>
          </div>
        </:footer>
      </CoreComponents.modal>
    </div>
    """
  end
end
