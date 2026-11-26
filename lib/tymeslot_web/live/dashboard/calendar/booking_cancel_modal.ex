defmodule TymeslotWeb.Dashboard.Calendar.BookingCancelModal do
  @moduledoc """
  Asks before a booking is cancelled from the calendar, with the Meetings
  page's dialog (`CancelMeetingModal`), including its refund choices for a
  paid booking, the host's last refund choice and the errors beside it
  (`BookingsManagement.Cancellation`). Submitting sends
  `booking:confirm_cancel` with the form; Keep meeting, Escape and a click
  outside send `booking:close`.
  """

  use TymeslotWeb, :html

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.Dashboard.Meetings.CancelMeetingModal

  attr :meeting, :map, required: true
  attr :booking_payment, :map, default: nil
  attr :seat_payments, :list, default: []
  attr :refund_error, :map, required: true
  attr :refund_form, :map, required: true
  attr :timezone, :string, required: true
  attr :time_format, :string, required: true
  attr :target, :any, required: true

  @spec booking_cancel_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def booking_cancel_modal(assigns) do
    ~H"""
    <CancelMeetingModal.cancel_meeting_modal
      id="calendar-cancel-booking"
      show
      meeting={@meeting}
      booking_payment={@booking_payment}
      seat_payments={@seat_payments}
      refund_error={@refund_error}
      refund_form={@refund_form}
      timezone={@timezone}
      time_format={@time_format}
      cancelling={false}
      on_cancel={JS.push("booking:close", value: %{modal: "cancel"}, target: @target)}
      confirm_event="booking:confirm_cancel"
      target={@target}
    />
    """
  end
end
