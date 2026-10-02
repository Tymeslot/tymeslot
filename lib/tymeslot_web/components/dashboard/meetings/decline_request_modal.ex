defmodule TymeslotWeb.Components.Dashboard.Meetings.DeclineRequestModal do
  @moduledoc """
  Confirms declining a booking request, and collects the host's optional note.

  Separate from the cancellation modal it resembles, because the two say
  different things to different people. Cancelling ends a meeting both sides
  agreed to; declining refuses one that was only ever asked for, and the
  invitee is told the slot is free again rather than that their meeting is
  off.

  The reason field is genuinely optional and labelled so. A declined request
  with a note reads as a person answering; forcing one would produce a field
  full of "n/a", which is worse than the honest absence the email template
  already handles.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Components.Dashboard.Meetings.Helpers

  attr :id, :string, required: true
  attr :show, :boolean, required: true
  attr :meeting, :map, required: true
  attr :timezone, :string, default: "UTC"
  attr :time_format, :string, default: "24h"
  attr :declining, :boolean, required: true
  attr :on_cancel, Phoenix.LiveView.JS, required: true
  attr :confirm_event, :string, required: true
  attr :target, :any, required: true

  @spec decline_request_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def decline_request_modal(assigns) do
    ~H"""
    <CoreComponents.confirm_modal
      id={@id}
      show={@show}
      title={dgettext("dashboard_bookings", "Decline request")}
      confirm_label={dgettext("dashboard_bookings", "Decline request")}
      cancel_label={dgettext("dashboard_bookings", "Keep it open")}
      confirm_form="decline-request-form"
      loading={@declining}
      loading_label={dgettext("dashboard_bookings", "Declining...")}
      on_cancel={@on_cancel}
    >
      <form
        :if={@meeting}
        id="decline-request-form"
        phx-submit={@confirm_event}
        phx-target={@target}
        class="space-y-4"
      >
        <p>
          {dgettext(
            "dashboard_bookings",
            "Decline the request from %{name} for %{when}?",
            name: @meeting.attendee_name,
            when:
              "#{Helpers.format_meeting_date(@meeting, @timezone)} • #{Helpers.format_meeting_time(@meeting, @timezone, @time_format)}"
          )}
        </p>

        <CoreComponents.input
          type="textarea"
          name="reason"
          value=""
          label={dgettext("dashboard_bookings", "Reason (optional)")}
          placeholder={
            dgettext("dashboard_bookings", "Shared with %{name} in the email they receive.",
              name: @meeting.attendee_name
            )
          }
          maxlength={Constraints.decline_reason_max_length()}
        />

        <p class="text-tymeslot-500">
          {dgettext(
            "dashboard_bookings",
            "The slot is released immediately and %{name} is told it wasn't confirmed.",
            name: @meeting.attendee_name
          )}
        </p>
      </form>
    </CoreComponents.confirm_modal>
    """
  end
end
