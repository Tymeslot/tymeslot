defmodule TymeslotWeb.Components.Dashboard.Profile.DeleteAvatarModal do
  @moduledoc """
  Modal for confirming avatar deletion.
  Implemented as a LiveComponent to handle its own state and deletion logic.
  """

  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

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

        Flash.info(dgettext("dashboard_profile", "Avatar deleted successfully"))

        {:noreply, assign(socket, :show, false)}

      {:error, reason} ->
        Flash.error(
          dgettext("dashboard_profile", "Failed to delete avatar: %{reason}",
            reason: inspect(reason)
          )
        )

        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <CoreComponents.confirm_modal
        id={"#{@id}-modal"}
        show={@show}
        title={dgettext("dashboard_profile", "Delete Avatar")}
        confirm_label={dgettext("dashboard_profile", "Delete Avatar")}
        on_cancel={JS.push("hide", target: @myself)}
        on_confirm={JS.push("confirm", target: @myself)}
      >
        <p>
          {dgettext(
            "dashboard_profile",
            "Are you sure you want to delete your profile picture? This action cannot be undone."
          )}
        </p>
      </CoreComponents.confirm_modal>
    </div>
    """
  end
end
