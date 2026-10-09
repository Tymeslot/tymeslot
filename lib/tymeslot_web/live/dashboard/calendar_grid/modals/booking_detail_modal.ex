defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.BookingDetailModal do
  @moduledoc """
  Read-only detail modal for a Tymeslot booking shown on the calendar grid.

  Bookings are managed through the booking flows (cancel with refund handling,
  reschedule requests) rather than edited like provider events, so this modal
  presents the booking and links to the Meetings page for those actions. Its
  body and actions are `AppointmentDetails`, shared with the overview's agenda
  modal; the booking is described as an `Agenda.Entry`.

  A group booking also lists its live participants, shows how many of its
  seats are taken and, beside the actions, why it cannot be moved or deleted
  from the calendar: the same wording the grid's lock badge and its refusals
  use.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.Agenda
  alias Tymeslot.CalendarGrid.BookingEvent
  alias TymeslotWeb.Components.Dashboard.Appointments.AppointmentDetails
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
  alias TymeslotWeb.Dashboard.DashboardFormat

  attr :booking, BookingEvent, required: true
  attr :user_timezone, :string, required: true
  attr :time_format, :string, required: true
  attr :now, DateTime, required: true, doc: "The grid's clock, anchoring the countdown"
  attr :myself, :any, required: true

  @spec booking_detail_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def booking_detail_modal(assigns) do
    assigns =
      assign(assigns,
        entry: Agenda.entry_for_grid_event(assigns.booking, assigns.user_timezone),
        group?: group?(assigns.booking)
      )

    ~H"""
    <.modal
      id="booking-detail-modal"
      show={true}
      on_cancel={JS.push("close_booking_detail", target: @myself)}
      size={:medium}
    >
      <:header>
        <%!-- A long booking title wraps rather than truncating, so it stays readable. --%>
        <div class="flex items-start gap-2 min-w-0">
          <img src="/images/brand/logo.svg" alt="" class="w-5 h-5 mt-1 sm:mt-1.5 shrink-0" />
          <span class="min-w-0 break-words">{DashboardFormat.title(@entry.title)}</span>
        </div>
      </:header>

      <div class="space-y-4" data-testid="booking-detail">
        <AppointmentDetails.appointment_details
          entry={@entry}
          timezone={@user_timezone}
          time_format={@time_format}
          now={@now}
        />

        <.detail_line
          :if={@booking.participants != []}
          icon="hero-user-group"
          label={dgettext("dashboard_calendar", "Participants")}
          data-testid="booking-participants"
        >
          <.pill :if={@group?} tone={:brand} class="mb-2" data-testid="booking-seats">
            {dgettext("dashboard_calendar", "%{count}/%{capacity} seats taken",
              count: @booking.seats_taken,
              capacity: @booking.capacity
            )}
          </.pill>
          <ul class="min-w-0 space-y-2">
            <li :for={participant <- @booking.participants} class="min-w-0">
              <span :if={participant.name} class="block">{participant.name}</span>
              <a
                href={"mailto:#{participant.email}"}
                class="block text-token-sm font-semibold text-tymeslot-500 hover:text-turquoise-600 truncate"
              >
                {participant.email}
              </a>
            </li>
          </ul>
        </.detail_line>
      </div>

      <:footer>
        <div class="flex flex-wrap items-center justify-end gap-x-4 gap-y-2">
          <p
            :if={@group?}
            class="flex items-start gap-1.5 text-token-xs text-tymeslot-500 min-w-0 flex-1 basis-56"
            data-testid="booking-lock-note"
          >
            <.icon name="hero-lock-closed-micro" class="w-3.5 h-3.5 shrink-0 mt-px" />
            <span>{Shared.seat_lock_message()}</span>
          </p>
          <AppointmentDetails.appointment_actions entry={@entry} />
        </div>
      </:footer>
    </.modal>
    """
  end

  defp group?(%{participants: [_first | _rest], capacity: capacity}) when capacity > 1,
    do: true

  defp group?(_booking), do: false
end
