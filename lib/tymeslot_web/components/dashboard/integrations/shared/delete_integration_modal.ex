defmodule TymeslotWeb.Components.Dashboard.Integrations.Shared.DeleteIntegrationModal do
  @moduledoc """
  Shared delete confirmation modal for integration components.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents

  @doc """
  Renders a delete confirmation modal for integrations.

  ## Attributes

    * `id` - The modal ID (required)
    * `show` - Boolean to show/hide the modal (required)
    * `integration_type` - The type of integration (:calendar or :video) (required)
    * `on_cancel` - JS command to execute when canceling (required)
    * `on_confirm` - JS command to execute when confirming deletion (required)

  ## Examples

      <DeleteIntegrationModal.delete_integration_modal
        id="delete-calendar-modal"
        show={@show_delete_modal}
        integration_type={:calendar}
        on_cancel={JS.push("hide_delete_modal", target: @myself)}
        on_confirm={JS.push("delete_integration", target: @myself)}
      />
  """
  attr :id, :string, required: true
  attr :show, :boolean, required: true
  attr :integration_type, :atom, required: true, values: [:calendar, :video]
  attr :on_cancel, JS, required: true
  attr :on_confirm, JS, required: true
  @spec delete_integration_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def delete_integration_modal(assigns) do
    ~H"""
    <CoreComponents.modal id={@id} show={@show} on_cancel={@on_cancel}>
      <:header>
        <svg class="w-5 h-5 text-red-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L3.732 16.5c-.77.833.192 2.5 1.732 2.5z"
          />
        </svg>
        Delete {format_integration_type(@integration_type)} Integration
      </:header>
      <p>
        Are you sure you want to delete this {format_integration_type(@integration_type)
        |> String.downcase()} integration?
        This action cannot be undone and will remove all associated {format_integration_data(
          @integration_type
        )}.
      </p>
      <:footer>
        <CoreComponents.action_button variant={:secondary} phx-click={@on_cancel}>
          Cancel
        </CoreComponents.action_button>
        <CoreComponents.action_button variant={:danger} phx-click={@on_confirm}>
          Delete Integration
        </CoreComponents.action_button>
      </:footer>
    </CoreComponents.modal>
    """
  end

  # Private helper functions

  defp format_integration_type(:calendar), do: "Calendar"
  defp format_integration_type(:video), do: "Video"

  defp format_integration_data(:calendar), do: "calendar data"
  defp format_integration_data(:video), do: "video conferencing configuration"
end
