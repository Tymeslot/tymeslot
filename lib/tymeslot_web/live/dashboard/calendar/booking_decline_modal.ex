defmodule TymeslotWeb.Dashboard.Calendar.BookingDeclineModal do
  @moduledoc """
  Asks before a request is declined from the calendar, with the Meetings
  page's dialog and its optional note (`DeclineRequestModal`). Submitting
  sends `booking:confirm_decline`; Keep it open, Escape and a click outside
  send `booking:close`.
  """

  use TymeslotWeb, :html

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.Dashboard.Meetings.DeclineRequestModal

  attr :meeting, :map, required: true
  attr :declining, :boolean, default: false
  attr :timezone, :string, required: true
  attr :time_format, :string, required: true
  attr :target, :any, required: true

  @spec booking_decline_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def booking_decline_modal(assigns) do
    ~H"""
    <DeclineRequestModal.decline_request_modal
      id="calendar-decline-request"
      show
      meeting={@meeting}
      timezone={@timezone}
      time_format={@time_format}
      declining={@declining}
      on_cancel={JS.push("booking:close", value: %{modal: "decline"}, target: @target)}
      confirm_event="booking:confirm_decline"
      target={@target}
    />
    """
  end
end
