defmodule TymeslotWeb.Components.Dashboard.Availability.ClearDayModal do
  @moduledoc """
  Modal component for confirming day settings clear.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents

  @doc """
  Renders a clear day settings confirmation modal.

  ## Attributes

    * `id` - The modal ID (required)
    * `show` - Boolean to show/hide the modal (required)
    * `day_data` - Map containing day number and day_name (required)
    * `on_cancel` - JS command to execute when canceling (required)
    * `on_confirm` - JS command to execute when confirming clear (required)

  ## Examples

      <ClearDayModal.clear_day_modal
        id="clear-day-modal"
        show={@show_clear_day_modal}
        day_data={@clear_day_modal_data}
        on_cancel={JS.push("hide_clear_day_modal", target: @myself)}
        on_confirm={JS.push("confirm_clear_day", target: @myself)}
      />
  """
  attr :id, :string, required: true
  attr :show, :boolean, required: true
  attr :day_data, :map, required: true
  attr :on_cancel, JS, required: true
  attr :on_confirm, JS, required: true

  @spec clear_day_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def clear_day_modal(assigns) do
    ~H"""
    <CoreComponents.modal id={@id} show={@show} on_cancel={@on_cancel}>
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
          Clear Day Settings
        </div>
      </:header>

      <%= if @day_data do %>
        <p>
          Are you sure you want to clear all settings for <strong><%= @day_data.day_name %></strong>?
        </p>
        <p class="mt-2 text-sm text-gray-600">
          This will remove all availability hours and breaks for this day. This action cannot be undone.
        </p>
      <% end %>

      <:footer>
        <CoreComponents.action_button variant={:secondary} phx-click={@on_cancel}>
          Cancel
        </CoreComponents.action_button>
        <CoreComponents.action_button variant={:danger} phx-click={@on_confirm}>
          Clear All Settings
        </CoreComponents.action_button>
      </:footer>
    </CoreComponents.modal>
    """
  end
end
