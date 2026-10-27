defmodule TymeslotWeb.Components.Dashboard.Meetings.CalendarMoveModal do
  @moduledoc """
  The confirmation for moving a booking to the time its calendar event now has.

  Distinct from the reschedule request: nothing is asked of the attendee and no
  new time is chosen. The booking follows a change the host already made, and
  the attendee is told about it afterwards.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents.Buttons
  alias TymeslotWeb.Components.CoreComponents.Icons
  alias TymeslotWeb.Components.CoreComponents.Modal
  alias TymeslotWeb.Components.Dashboard.Meetings.Helpers

  attr :id, :string, required: true
  attr :show, :boolean, required: true
  attr :data, :map, default: nil, doc: "`%{meeting: meeting, offer: offer}`, or nil when closed"
  attr :timezone, :string, default: "UTC"
  attr :time_format, :string, default: "24h"
  attr :on_cancel, JS, required: true
  attr :on_confirm, JS, required: true

  @spec calendar_move_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def calendar_move_modal(assigns) do
    ~H"""
    <Modal.modal id={@id} show={@show} on_cancel={@on_cancel} size={:medium}>
      <:header>
        <div class="flex items-center gap-2">
          <Icons.icon name="hero-calendar-days" class="w-5 h-5 text-turquoise-600" />
          {dgettext("dashboard_bookings", "Move booking to the new time")}
        </div>
      </:header>

      <p :if={@data} class="text-tymeslot-600 font-medium text-lg leading-relaxed">
        {dgettext(
          "dashboard_bookings",
          "Your calendar now has this meeting at %{time}. Tymeslot will move the booking there, reschedule its reminders and email %{attendee_name} and any guests the new time.",
          time: Helpers.format_move_time(@data.offer, @timezone, @time_format),
          attendee_name: @data.meeting.attendee_name
        )}
      </p>

      <:footer>
        <div class="flex justify-end gap-3">
          <Buttons.action_button variant={:secondary} phx-click={@on_cancel}>
            {dgettext("common", "Cancel")}
          </Buttons.action_button>
          <Buttons.action_button
            variant={:primary}
            phx-click={@on_confirm}
            data-testid="confirm-calendar-move"
          >
            {dgettext("dashboard_bookings", "Move booking")}
          </Buttons.action_button>
        </div>
      </:footer>
    </Modal.modal>
    """
  end
end
