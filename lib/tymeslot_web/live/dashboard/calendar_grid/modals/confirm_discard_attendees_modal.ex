defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.ConfirmDiscardAttendeesModal do
  @moduledoc "Confirmation modal for discarding unsent attendee invitations."

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS

  attr :count, :integer, required: true
  attr :myself, :any, required: true

  @spec confirm_discard_attendees_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def confirm_discard_attendees_modal(assigns) do
    ~H"""
    <.modal
      id="confirm-discard-attendees-modal"
      show={true}
      on_cancel={JS.push("cancel_discard_attendees", target: @myself)}
      size={:small}
    >
      <:header>{dgettext("dashboard_calendar_events", "Unsent invitations")}</:header>

      <p class="text-token-sm text-tymeslot-500">
        {dngettext(
          "dashboard_calendar_events",
          "%{count} attendee hasn't been invited yet. Discard?",
          "%{count} attendees haven't been invited yet. Discard?",
          @count
        )}
      </p>

      <:footer>
        <div class="flex gap-2">
          <.action_button
            variant={:danger}
            phx-click="discard_pending_attendees"
            phx-target={@myself}
          >
            {dgettext("dashboard_calendar_events", "Discard")}
          </.action_button>
          <.action_button
            variant={:secondary}
            phx-click={JS.push("cancel_discard_attendees", target: @myself)}
          >
            {dgettext("dashboard_calendar_events", "Go back")}
          </.action_button>
        </div>
      </:footer>
    </.modal>
    """
  end
end
