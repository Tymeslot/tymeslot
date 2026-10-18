defmodule TymeslotWeb.Dashboard.Calendar.BookingRescheduleModal do
  @moduledoc """
  Asks before the guest is asked for a new time from the calendar, with the
  Meetings page's dialog (`RescheduleRequestModal`), which says what happens
  next: the current slot is released and the guest picks again. Send Request
  sends `booking:confirm_reschedule`; Cancel, Escape and a click outside send
  `booking:close`.
  """

  use TymeslotWeb, :html

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.Dashboard.Meetings.RescheduleRequestModal

  attr :meeting, :map, required: true
  attr :sending, :boolean, default: false
  attr :timezone, :string, required: true
  attr :time_format, :string, required: true
  attr :target, :any, required: true

  @spec booking_reschedule_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def booking_reschedule_modal(assigns) do
    ~H"""
    <RescheduleRequestModal.reschedule_request_modal
      id="calendar-reschedule-booking"
      show
      meeting={@meeting}
      timezone={@timezone}
      time_format={@time_format}
      sending={@sending}
      on_cancel={JS.push("booking:close", value: %{modal: "reschedule"}, target: @target)}
      on_confirm={JS.push("booking:confirm_reschedule", target: @target)}
    />
    """
  end
end
