defmodule TymeslotWeb.Dashboard.Calendar.SurfaceModals do
  @moduledoc """
  The calendar surface's dialogs: which events of a repeating series a
  change applies to, the delete confirmation, moving a series to another
  calendar, removing a guest, and the booking dialogs (decline a request,
  cancel a booking, ask for a reschedule, move a booking to its calendar
  time). Each shows while its prompt or
  modal data is set. All are core modals, which become bottom sheets on a
  phone.
  """

  use TymeslotWeb, :html

  alias TymeslotWeb.Dashboard.Calendar.BookingCancelModal
  alias TymeslotWeb.Dashboard.Calendar.BookingDeclineModal
  alias TymeslotWeb.Dashboard.Calendar.BookingMoveModal
  alias TymeslotWeb.Dashboard.Calendar.BookingRescheduleModal
  alias TymeslotWeb.Dashboard.Calendar.DeleteConfirmModal
  alias TymeslotWeb.Dashboard.Calendar.RemoveGuestModal
  alias TymeslotWeb.Dashboard.Calendar.SeriesMoveModal
  alias TymeslotWeb.Dashboard.Calendar.SeriesScopeModal

  attr :series_prompt, :map, default: nil
  attr :delete_prompt, :map, default: nil
  attr :series_move_prompt, :map, default: nil
  attr :remove_guest_prompt, :map, default: nil
  attr :decline_request_modal_data, :map, default: nil
  attr :cancel_meeting_modal_data, :map, default: nil
  attr :cancel_booking_payment, :any, default: nil
  attr :reschedule_request_modal_data, :map, default: nil
  attr :calendar_move_modal_data, :map, default: nil
  attr :answering_request, :any, required: true, doc: "the request ids being answered"
  attr :sending_reschedule, :any, default: nil
  attr :timezone, :string, required: true
  attr :time_format, :string, required: true
  attr :target, :any, required: true

  @spec modals(map()) :: Phoenix.LiveView.Rendered.t()
  def modals(assigns) do
    ~H"""
    <SeriesScopeModal.series_scope_modal
      :if={@series_prompt}
      prompt={@series_prompt}
      target={@target}
    />
    <DeleteConfirmModal.delete_confirm_modal
      :if={@delete_prompt}
      prompt={@delete_prompt}
      target={@target}
    />
    <SeriesMoveModal.series_move_modal
      :if={@series_move_prompt}
      prompt={@series_move_prompt}
      target={@target}
    />
    <RemoveGuestModal.remove_guest_modal
      :if={@remove_guest_prompt}
      prompt={@remove_guest_prompt}
      target={@target}
    />
    <BookingDeclineModal.booking_decline_modal
      :if={@decline_request_modal_data}
      meeting={@decline_request_modal_data}
      declining={MapSet.member?(@answering_request, @decline_request_modal_data.id)}
      timezone={@timezone}
      time_format={@time_format}
      target={@target}
    />
    <BookingCancelModal.booking_cancel_modal
      :if={@cancel_meeting_modal_data}
      meeting={@cancel_meeting_modal_data}
      booking_payment={@cancel_booking_payment}
      timezone={@timezone}
      time_format={@time_format}
      target={@target}
    />
    <BookingRescheduleModal.booking_reschedule_modal
      :if={@reschedule_request_modal_data}
      meeting={@reschedule_request_modal_data}
      sending={not is_nil(@sending_reschedule)}
      timezone={@timezone}
      time_format={@time_format}
      target={@target}
    />
    <BookingMoveModal.booking_move_modal
      :if={@calendar_move_modal_data}
      data={@calendar_move_modal_data}
      timezone={@timezone}
      time_format={@time_format}
      target={@target}
    />
    """
  end
end
