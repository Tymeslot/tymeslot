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
    <.confirm_modal
      id="confirm-remove-attendee-modal"
      show
      size={:small}
      title={dgettext("dashboard_calendar_events", "Remove attendee")}
      confirm_label={dgettext("dashboard_calendar_events", "Remove")}
      on_cancel={JS.push("cancel_remove_attendee", target: @myself)}
      on_confirm={JS.push("confirm_remove_attendee", target: @myself)}
    >
      <p>
        {dgettext("dashboard_calendar_events", "Remove")}
        <span class="text-tymeslot-900"><%= @confirm_remove_attendee.email %></span>?
      </p>
      <p class="text-amber-600">
        {dgettext(
          "dashboard_calendar_events",
          "This person will receive a cancellation from your calendar provider."
        )}
      </p>
    </.confirm_modal>
    """
  end
end
