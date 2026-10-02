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
    <.confirm_modal
      id="confirm-discard-attendees-modal"
      show
      size={:small}
      title={dgettext("dashboard_calendar_events", "Unsent invitations")}
      confirm_label={dgettext("dashboard_calendar_events", "Discard")}
      cancel_label={dgettext("dashboard_calendar_events", "Go back")}
      on_cancel={JS.push("cancel_discard_attendees", target: @myself)}
      on_confirm={JS.push("discard_pending_attendees", target: @myself)}
    >
      <p>
        {dngettext(
          "dashboard_calendar_events",
          "%{count} attendee hasn't been invited yet. Discard?",
          "%{count} attendees haven't been invited yet. Discard?",
          @count
        )}
      </p>
    </.confirm_modal>
    """
  end
end
