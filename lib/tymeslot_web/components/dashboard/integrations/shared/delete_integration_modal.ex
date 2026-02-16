defmodule TymeslotWeb.Components.Dashboard.Integrations.Shared.DeleteIntegrationModal do
  @moduledoc """
  Shared delete confirmation modal for integration components.
  Now implemented as a LiveComponent to handle its own state and deletion logic.
  """

  use TymeslotWeb, :live_component

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Video
  alias TymeslotWeb.Dashboard.{CalendarSettingsComponent, VideoSettingsComponent}

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> assign(:show, false)
     |> assign(:integration_id, nil)}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("show", %{"id" => id}, socket) do
    case parse_integration_id(id) do
      {:ok, integration_id} ->
        {:noreply,
         socket
         |> assign(:show, true)
         |> assign(:integration_id, integration_id)}

      {:error, _reason} ->
        Flash.error("Invalid integration ID")
        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveComponent
  def handle_event("hide", _params, socket) do
    {:noreply,
     socket
     |> assign(:show, false)
     |> assign(:integration_id, nil)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("confirm", _params, socket) do
    # Guard against nil or invalid integration_id
    case socket.assigns.integration_id do
      nil ->
        Flash.error("No integration selected for deletion")

        {:noreply,
         socket
         |> assign(:show, false)
         |> assign(:integration_id, nil)}

      integration_id when is_integer(integration_id) ->
        user_id = socket.assigns.current_user.id
        type = socket.assigns.integration_type

        result =
          case type do
            :calendar ->
              Calendar.delete_with_primary_reassignment_and_invalidate(user_id, integration_id)

            :video ->
              Video.delete_integration(user_id, integration_id)
          end

        case result do
          {:ok, _} ->
            # Notify the parent LiveView (usually DashboardLive) to refresh lists
            send(self(), {:integration_removed, type})

            # Also trigger a reload of the parent component
            # The parent component ID is typically the action name (e.g., "calendar", "video")
            parent_component_id = get_parent_component_id(type)
            parent_component_module = get_parent_component_module(type)

            send_update(parent_component_module, id: parent_component_id)

            Flash.info("Integration deleted successfully")

            {:noreply,
             socket
             |> assign(:show, false)
             |> assign(:integration_id, nil)}

          {:error, :not_found} ->
            Flash.error("Integration not found. It may have already been deleted.")

            {:noreply,
             socket
             |> assign(:show, false)
             |> assign(:integration_id, nil)}

          {:error, _reason} ->
            Flash.error("Failed to delete integration")
            {:noreply, socket}
        end

      _ ->
        Flash.error("Invalid integration ID")

        {:noreply,
         socket
         |> assign(:show, false)
         |> assign(:integration_id, nil)}
    end
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <TymeslotWeb.Components.CoreComponents.modal
        id={"#{@id}-modal"}
        show={@show}
        on_cancel={JS.push("hide", target: @myself)}
        size={:small}
      >
        <:header>
          <div class="flex items-center gap-2">
            <svg class="w-5 h-5 text-red-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L3.732 16.5c-.77.833.192 2.5 1.732 2.5z"
              />
            </svg>
            Delete {format_integration_type(@integration_type)} Integration
          </div>
        </:header>
        <div class="space-y-4">
          <p class="text-tymeslot-600 font-medium text-lg leading-relaxed">
            Are you sure you want to delete this {format_integration_type(@integration_type)
            |> String.downcase()} integration?
          </p>
          <p class="text-tymeslot-500 font-medium">
            This action cannot be undone and will remove all associated {format_integration_data(
              @integration_type
            )}.
          </p>
        </div>
        <:footer>
          <div class="flex justify-end gap-3">
            <TymeslotWeb.Components.CoreComponents.action_button
              variant={:secondary}
              phx-click={JS.push("hide", target: @myself)}
            >
              Cancel
            </TymeslotWeb.Components.CoreComponents.action_button>
            <TymeslotWeb.Components.CoreComponents.action_button
              variant={:danger}
              phx-click={JS.push("confirm", target: @myself)}
            >
              Delete Integration
            </TymeslotWeb.Components.CoreComponents.action_button>
          </div>
        </:footer>
      </TymeslotWeb.Components.CoreComponents.modal>
    </div>
    """
  end

  # Private helper functions

  defp get_parent_component_module(:calendar), do: CalendarSettingsComponent
  defp get_parent_component_module(:video), do: VideoSettingsComponent

  defp get_parent_component_id(:calendar), do: "calendar"
  defp get_parent_component_id(:video), do: "video"

  defp format_integration_type(:calendar), do: "Calendar"
  defp format_integration_type(:video), do: "Video"

  defp format_integration_data(:calendar), do: "calendar data"
  defp format_integration_data(:video), do: "video conferencing configuration"

  # Safe integer parsing that handles invalid input gracefully
  defp parse_integration_id(id) when is_integer(id), do: {:ok, id}

  defp parse_integration_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} when int > 0 -> {:ok, int}
      {int, _rest} when int > 0 -> {:error, :invalid_format}
      {_int, _} -> {:error, :invalid_value}
      :error -> {:error, :not_a_number}
    end
  end

  defp parse_integration_id(_), do: {:error, :invalid_type}
end
