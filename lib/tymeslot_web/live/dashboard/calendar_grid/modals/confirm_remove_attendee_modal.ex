defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.ConfirmRemoveAttendeeModal do
  @moduledoc "Confirmation modal for removing an attendee from a calendar event."

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS

  attr :confirm_remove_attendee, :map, required: true
  attr :myself, :any, required: true

  @spec confirm_remove_attendee_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def confirm_remove_attendee_modal(assigns) do
    ~H"""
    <.modal
      id="confirm-remove-attendee-modal"
      show={true}
      on_cancel={JS.push("cancel_remove_attendee", target: @myself)}
      size={:small}
    >
      <:header>{dgettext("dashboard_calendar_events", "Remove attendee")}</:header>

      <p class="text-token-sm text-tymeslot-500">
        {dgettext("dashboard_calendar_events", "Remove")}
        <span class="font-medium text-tymeslot-700"><%= @confirm_remove_attendee.email %></span>?
      </p>
      <p class="mt-2 text-token-sm text-amber-600">
        {dgettext(
          "dashboard_calendar_events",
          "This person will receive a cancellation from your calendar provider."
        )}
      </p>

      <:footer>
        <div class="flex gap-2">
          <.action_button
            variant={:danger}
            phx-click="confirm_remove_attendee"
            phx-target={@myself}
          >
            {dgettext("dashboard_calendar_events", "Remove")}
          </.action_button>
          <.action_button
            variant={:secondary}
            phx-click={JS.push("cancel_remove_attendee", target: @myself)}
          >
            {dgettext("dashboard_calendar_events", "Cancel")}
          </.action_button>
        </div>
      </:footer>
    </.modal>
    """
  end
end
