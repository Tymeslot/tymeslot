defmodule TymeslotWeb.Dashboard.BookingsManagement.Modals do
  @moduledoc """
  The three modals the bookings dashboard can open, in one place.

  Extracted from the component's `render/1` so the list, its tabs, and the
  loading states stay readable: the modals are always mounted and almost always
  hidden, so fifty lines of markup sat between the page and its own footer.

  Each one owns a different decision about a booking, and they are deliberately
  distinct rather than one parameterised modal. Cancelling ends a meeting both
  sides agreed to; declining refuses one that was only ever requested; asking
  for a reschedule proposes a new time. Collapsing them would mean one body of
  copy trying to say all three things.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  alias TymeslotWeb.Components.Dashboard.Meetings.{
    CancelMeetingModal,
    DeclineRequestModal,
    Helpers,
    RescheduleRequestModal
  }

  attr :cancel_meeting, :map, default: nil
  attr :show_cancel, :boolean, required: true
  attr :cancel_booking_payment, :map, default: nil
  attr :cancelling, :boolean, required: true
  attr :decline_request, :map, default: nil
  attr :show_decline, :boolean, required: true
  attr :declining, :boolean, required: true
  attr :reschedule_request, :map, default: nil
  attr :show_reschedule, :boolean, required: true
  attr :sending_reschedule, :any, default: nil
  attr :profile, :any, default: nil
  attr :time_format, :string, required: true
  attr :target, :any, required: true

  @spec booking_modals(map()) :: Phoenix.LiveView.Rendered.t()
  def booking_modals(assigns) do
    ~H"""
    <CancelMeetingModal.cancel_meeting_modal
      id="cancel-meeting-modal"
      show={@show_cancel}
      meeting={@cancel_meeting}
      booking_payment={@cancel_booking_payment}
      timezone={timezone_for(@cancel_meeting, @profile)}
      time_format={@time_format}
      cancelling={@cancelling}
      on_cancel={JS.push("hide_cancel_modal", target: @target)}
      confirm_event="confirm_cancel_meeting"
      target={@target}
    />

    <DeclineRequestModal.decline_request_modal
      id="decline-request-modal"
      show={@show_decline}
      meeting={@decline_request}
      timezone={timezone_for(@decline_request, @profile)}
      time_format={@time_format}
      declining={@declining}
      on_cancel={JS.push("hide_decline_modal", target: @target)}
      confirm_event="confirm_decline_request"
      target={@target}
    />

    <RescheduleRequestModal.reschedule_request_modal
      id="reschedule-request-modal"
      show={@show_reschedule}
      meeting={@reschedule_request}
      timezone={timezone_for(@reschedule_request, @profile)}
      time_format={@time_format}
      sending={
        !!(@reschedule_request && @sending_reschedule &&
             @sending_reschedule == @reschedule_request.id)
      }
      on_cancel={JS.push("hide_reschedule_modal", target: @target)}
      on_confirm={JS.push("confirm_reschedule_request", target: @target)}
    />
    """
  end

  # A modal with no meeting loaded renders hidden, so the timezone is never
  # shown; UTC is the placeholder rather than a claim about anything.
  defp timezone_for(nil, _profile), do: "UTC"
  defp timezone_for(meeting, profile), do: Helpers.get_meeting_timezone(meeting, profile)
end
