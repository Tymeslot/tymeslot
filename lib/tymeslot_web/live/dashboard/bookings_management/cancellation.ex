defmodule TymeslotWeb.Dashboard.BookingsManagement.Cancellation do
  @moduledoc """
  Telemetry and user-facing copy for cancelling a booking from the dashboard.

  Split out of `BookingsManagementComponent` to keep that module inside the
  size limit. `cancel/4` runs a confirmed cancellation and says how it went,
  so the Meetings page and the calendar's preview (`Calendar.BookingActions`)
  act and speak alike; the socket-threading stays with each caller.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Bookings.Refusal
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings
  alias TymeslotWeb.Dashboard.BookingsManagement.ModalMeeting

  require Logger
  require Refusal

  @event_prefix [:tymeslot, :dashboard, :meetings, :cancel]

  @doc "Records that the host opened the cancel dialog."
  @spec emit_open(integer(), binary()) :: :ok
  def emit_open(user_id, meeting_id) do
    :telemetry.execute(
      @event_prefix ++ [:open],
      %{},
      %{user_id: user_id, meeting_id: meeting_id}
    )
  end

  @doc """
  Records a cancellation the host was not allowed to make: `:validation_failed`
  for a malformed request, anything else for one the domain refused.
  """
  @spec emit_error(integer(), term(), atom()) :: :ok
  def emit_error(user_id, reason, tag) do
    event = if tag == :validation_failed, do: :validation_failed, else: :blocked

    :telemetry.execute(
      @event_prefix ++ [event],
      %{},
      %{user_id: user_id, reason: inspect(reason)}
    )
  end

  @doc "Records the outcome of a confirmed cancellation."
  @spec emit_confirm(integer(), binary(), term()) :: :ok
  def emit_confirm(user_id, meeting_id, result) do
    measurements = %{user_id: user_id, meeting_id: meeting_id}

    metadata =
      case result do
        {:ok, _cancelled} -> Map.put(measurements, :result, :ok)
        {:error, reason} -> Map.merge(measurements, %{result: :error, reason: inspect(reason)})
      end

    :telemetry.execute(@event_prefix ++ [:confirm], %{}, metadata)
  end

  @doc "The message shown when the refund the host asked for cannot be made."
  @spec refund_error_message(term()) :: String.t()
  def refund_error_message(:acknowledgement_required),
    do:
      dgettext(
        "dashboard_bookings",
        "Tick the acknowledgement to cancel without refunding the attendee."
      )

  def refund_error_message(:exceeds_remaining),
    do: dgettext("dashboard_bookings", "Refund amount exceeds the remaining refundable balance.")

  def refund_error_message(_reason),
    do: dgettext("dashboard_bookings", "Enter a valid partial refund amount.")

  @doc "The message shown once the cancellation has gone through."
  @spec success_message(term()) :: String.t()
  def success_message({:refund, _cents}),
    do: dgettext("dashboard_bookings", "Meeting cancelled and refund issued.")

  def success_message(:none),
    do: dgettext("dashboard_bookings", "Meeting cancelled successfully")

  @doc """
  The message shown when the meeting had been cancelled elsewhere before the
  host confirmed. A refund the host chose was not issued, so it says so.
  """
  @spec already_cancelled_message(term()) :: String.t()
  def already_cancelled_message({:refund, _cents}),
    do:
      dgettext(
        "dashboard_bookings",
        "This booking was already cancelled, so no refund was issued."
      )

  def already_cancelled_message(:none),
    do: dgettext("dashboard_bookings", "This booking was already cancelled.")

  @doc """
  Cancels `meeting` for the host `user_id`, with the refund the cancel form's
  `params` choose against `booking_payment` (nil for a free booking), and
  says how it went as `{outcome, flash_type, message}`:

    * `:closed`: the booking is cancelled (the refund may still have failed,
      or someone else cancelled it first; the message says which), so the
      dialog closes and the list reloads.
    * `:refused`: the meeting started or ended meanwhile; nothing changed and
      the dialog closes.
    * `:invalid` (a refund choice that does not add up) and `:failed`: the
      dialog stays open for another try.
  """
  @spec cancel(integer(), map(), map() | nil, map()) ::
          {:closed | :refused | :invalid | :failed, :info | :error, String.t()}
  def cancel(user_id, meeting, booking_payment, params) do
    case Meetings.resolve_cancellation_refund(booking_payment, params) do
      {:ok, refund_action} ->
        result = Meetings.cancel_meeting_with_refund(meeting, user_id, refund_action)
        emit_confirm(user_id, meeting.id, result)
        outcome(meeting, refund_action, result)

      {:error, reason} ->
        {:invalid, :error, refund_error_message(reason)}
    end
  end

  defp outcome(_meeting, refund_action, {:ok, _cancelled}),
    do: {:closed, :info, success_message(refund_action)}

  # The meeting is cancelled; only the money is outstanding.
  defp outcome(_meeting, _refund_action, {:error, {:refund_failed, _reason}}),
    do:
      {:closed, :error,
       dgettext(
         "dashboard_bookings",
         "Meeting cancelled but refund could not be issued. Please issue the refund manually from your Stripe dashboard."
       )}

  # The attendee (or a calendar sync) cancelled it while the dialog was open,
  # before the refund step, so no refund came from this action.
  defp outcome(_meeting, refund_action, {:error, :already_cancelled}),
    do: {:closed, :info, already_cancelled_message(refund_action)}

  defp outcome(_meeting, _refund_action, {:error, reason}) when Refusal.is_refusal(reason),
    do: {:refused, :error, ModalMeeting.refusal_message(reason)}

  defp outcome(meeting, _refund_action, {:error, reason}) do
    Logger.error("cancel_meeting_failed",
      reason: LogFormat.reason(reason),
      meeting_id: meeting.id
    )

    {:failed, :error,
     dgettext("dashboard_bookings", "Failed to cancel meeting. Please try again.")}
  end
end
