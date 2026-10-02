defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.BookingDetailModal do
  @moduledoc """
  Read-only detail modal for a Tymeslot booking shown on the calendar grid.

  Bookings are managed through the booking flows (cancel with refund handling,
  reschedule requests) rather than edited like provider events, so this modal
  presents the booking and links to the Meetings page for those actions. Its
  body and actions are `AppointmentDetails`, shared with the overview's agenda
  modal; the booking arrives as an `Agenda.Entry`.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.Agenda.Entry
  alias TymeslotWeb.Components.Dashboard.Appointments.AppointmentDetails
  alias TymeslotWeb.Dashboard.DashboardFormat

  attr :entry, Entry, required: true
  attr :user_timezone, :string, required: true
  attr :time_format, :string, required: true
  attr :myself, :any, required: true

  @spec booking_detail_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def booking_detail_modal(assigns) do
    assigns = assign(assigns, :now, DateTime.utc_now())

    ~H"""
    <.modal
      id="booking-detail-modal"
      show={true}
      on_cancel={JS.push("close_booking_detail", target: @myself)}
      size={:medium}
    >
      <:header>
        <div class="flex items-center gap-2 min-w-0">
          <img src="/images/brand/logo.svg" alt="" class="w-5 h-5 shrink-0" />
          <span class="truncate">{DashboardFormat.title(@entry.title)}</span>
        </div>
      </:header>

      <div data-testid="booking-detail">
        <AppointmentDetails.appointment_details
          entry={@entry}
          timezone={@user_timezone}
          time_format={@time_format}
          now={@now}
        />
      </div>

      <:footer>
        <AppointmentDetails.appointment_actions entry={@entry} />
      </:footer>
    </.modal>
    """
  end
end
