defmodule TymeslotWeb.Dashboard.Calendar.BookingMoveModal do
  @moduledoc """
  Asks before a booking follows its event to the time the host moved it to
  in their calendar, with the Meetings page's dialog (`CalendarMoveModal`),
  which says what happens: reminders follow and the attendee and guests are
  emailed the new time. Move booking sends `booking:confirm_move`; Cancel,
  Escape and a click outside send `booking:close`.
  """

  use TymeslotWeb, :html

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.Dashboard.Meetings.CalendarMoveModal

  attr :data, :map, required: true, doc: "`%{meeting: meeting, offer: offer}`"
  attr :timezone, :string, required: true
  attr :time_format, :string, required: true
  attr :target, :any, required: true

  @spec booking_move_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def booking_move_modal(assigns) do
    ~H"""
    <CalendarMoveModal.calendar_move_modal
      id="calendar-move-booking"
      show
      data={@data}
      timezone={@timezone}
      time_format={@time_format}
      on_cancel={JS.push("booking:close", value: %{modal: "move"}, target: @target)}
      on_confirm={JS.push("booking:confirm_move", target: @target)}
    />
    """
  end
end
