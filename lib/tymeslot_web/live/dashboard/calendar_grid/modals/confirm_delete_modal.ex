defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.ConfirmDeleteModal do
  @moduledoc "Confirmation modal for deleting a calendar event."

  use TymeslotWeb, :html

  alias Phoenix.LiveView.JS

  attr :event, :map, required: true
  attr :deleting, :boolean, default: false
  attr :linked_to_booking, :boolean, default: false
  attr :myself, :any, required: true

  @spec confirm_delete_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def confirm_delete_modal(assigns) do
    ~H"""
    <.modal
      id="confirm-delete-event-modal"
      show={true}
      on_cancel={JS.push("cancel_delete_event", target: @myself)}
      size={:small}
    >
      <:header>Delete event</:header>

      <p class="text-token-sm text-tymeslot-500">
        Are you sure you want to delete
        <span class="font-medium text-tymeslot-700"><%= @event.summary || "(No title)" %></span>?
        This will also remove it from your calendar provider.
      </p>
      <p :if={@linked_to_booking} class="mt-2 text-token-sm text-amber-600">
        This event is linked to a booking. The attendee will be notified of the cancellation.
      </p>

      <:footer>
        <div class="flex gap-2">
          <.loading_button
            variant={:danger}
            loading={@deleting}
            loading_text="Deleting..."
            phx-click="confirm_delete_event"
            phx-target={@myself}
          >
            Delete
          </.loading_button>
          <.action_button
            variant={:secondary}
            disabled={@deleting}
            phx-click={JS.push("cancel_delete_event", target: @myself)}
          >
            Cancel
          </.action_button>
        </div>
      </:footer>
    </.modal>
    """
  end
end
