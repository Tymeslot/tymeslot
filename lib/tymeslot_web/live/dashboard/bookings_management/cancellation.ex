defmodule TymeslotWeb.Dashboard.BookingsManagement.Cancellation do
  @moduledoc """
  Cancelling a booking from the bookings dashboard: opening the dialog,
  confirming it (with whatever refund the host chose), and the telemetry and
  user-facing copy that go with it.

  Split out of `BookingsManagementComponent` to keep that module inside the
  size limit. The reload is passed in rather than reached for: the list belongs
  to the component, and this module only says when it should be refreshed.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3]

  alias Tymeslot.Bookings.Refusal
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingSchema
  alias TymeslotWeb.Dashboard.BookingsManagement.ModalMeeting
  alias TymeslotWeb.Hooks.ModalHook
  alias TymeslotWeb.Live.Shared.Flash

  require Refusal

  require Logger

  @event_prefix [:tymeslot, :dashboard, :meetings, :cancel]

  @typep reload :: (Phoenix.LiveView.Socket.t() -> Phoenix.LiveView.Socket.t())

  @doc """
  Opens the cancel dialog for the host's meeting `params["id"]`, if `policy`
  allows its cancellation, along with any payment the host took for it (which
  is what offers the refund options). A refusal is flashed.
  """
  @spec show(Phoenix.LiveView.Socket.t(), map(), (MeetingSchema.t() -> :ok | {:error, term()})) ::
          Phoenix.LiveView.Socket.t()
  def show(socket, params, policy) do
    user_id = socket.assigns.current_user.id

    case ModalMeeting.fetch(user_id, params, policy) do
      {:ok, meeting} ->
        emit_open(user_id, meeting.id)

        # Scoped to the signed-in host: only a payment they took offers
        # refund options.
        booking_payment = MeetingPayments.payment_for_meeting(meeting.id, user_id)

        socket
        |> assign(:cancel_booking_payment, booking_payment)
        |> ModalHook.show_modal(:cancel_meeting, meeting)

      {:error, :validation_failed, reason} ->
        emit_error(user_id, reason, :validation_failed)
        socket

      {:error, :policy_blocked, reason} ->
        emit_error(user_id, reason, :blocked)
        Flash.error(ModalMeeting.refusal_message(reason))
        socket

      {:error, :not_found, _reason} ->
        socket
    end
  end

  @doc "Closes the cancel dialog without cancelling anything."
  @spec hide(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def hide(socket) do
    socket
    |> assign(:cancel_booking_payment, nil)
    |> ModalHook.hide_modal(:cancel_meeting)
  end

  @doc """
  Cancels `meeting` with the refund `params` describe and settles the dialog:
  closed and the list refreshed once the meeting is cancelled (even if only the
  refund failed), closed without a refresh when the domain refused, and left
  open for a retry on any other failure. A refund choice that does not
  validate leaves everything as it was.
  """
  @spec confirm(Phoenix.LiveView.Socket.t(), MeetingSchema.t(), map(), reload()) ::
          Phoenix.LiveView.Socket.t()
  def confirm(socket, meeting, params, reload) when is_function(reload, 1) do
    booking_payment = socket.assigns.cancel_booking_payment

    case Meetings.resolve_cancellation_refund(booking_payment, params) do
      {:ok, refund_action} ->
        socket
        |> assign(:cancelling_meeting, meeting.id)
        |> run_cancellation(meeting, refund_action, reload)

      {:error, reason} ->
        Flash.error(refund_error_message(reason))
        socket
    end
  end

  defp run_cancellation(socket, meeting, refund_action, reload) do
    result =
      Meetings.cancel_meeting_with_refund(
        meeting,
        socket.assigns.current_user.id,
        refund_action
      )

    emit_confirm(socket.assigns.current_user.id, meeting.id, result)
    handle_cancellation(socket, meeting, refund_action, result, reload)
  end

  defp handle_cancellation(socket, _meeting, refund_action, {:ok, _cancelled}, reload) do
    Flash.info(success_message(refund_action))
    close(socket, reload)
  end

  # The meeting is cancelled; only the money is outstanding. The modal closes
  # and the list refreshes as on success, because the cancellation itself did
  # happen and leaving the dialog open would suggest otherwise.
  defp handle_cancellation(
         socket,
         _meeting,
         _refund_action,
         {:error, {:refund_failed, _reason}},
         reload
       ) do
    Flash.error(
      dgettext(
        "dashboard_bookings",
        "Meeting cancelled but refund could not be issued. Please issue the refund manually from your Stripe dashboard."
      )
    )

    close(socket, reload)
  end

  # The attendee (or a calendar sync) cancelled the meeting while the modal
  # was open. Nothing is left to do: the cancellation stopped before the
  # refund step, so the host is told no refund came from this action.
  defp handle_cancellation(socket, _meeting, refund_action, {:error, :already_cancelled}, reload) do
    Flash.info(already_cancelled_message(refund_action))
    close(socket, reload)
  end

  # The meeting started or ended while the modal was open: retrying cannot
  # help, so the host is told why. Nothing changed, so the list stands.
  defp handle_cancellation(socket, _meeting, _refund_action, {:error, reason}, _reload)
       when Refusal.is_refusal(reason) do
    Flash.error(ModalMeeting.refusal_message(reason))

    socket
    |> assign(cancelling_meeting: nil, cancel_booking_payment: nil)
    |> ModalHook.hide_modal(:cancel_meeting)
  end

  defp handle_cancellation(socket, meeting, _refund_action, {:error, reason}, _reload) do
    Logger.error("cancel_meeting_failed",
      reason: LogFormat.reason(reason),
      meeting_id: meeting.id
    )

    Flash.error(dgettext("dashboard_bookings", "Failed to cancel meeting. Please try again."))
    assign(socket, :cancelling_meeting, nil)
  end

  defp close(socket, reload) do
    socket
    |> assign(:cancelling_meeting, nil)
    |> assign(:cancel_booking_payment, nil)
    |> reload.()
    |> ModalHook.hide_modal(:cancel_meeting)
  end

  # Records that the host opened the cancel dialog.
  defp emit_open(user_id, meeting_id) do
    :telemetry.execute(
      @event_prefix ++ [:open],
      %{},
      %{user_id: user_id, meeting_id: meeting_id}
    )
  end

  # Records a cancellation the host was not allowed to make: `:validation_failed`
  # for a malformed request, anything else for one the domain refused.
  defp emit_error(user_id, reason, tag) do
    event = if tag == :validation_failed, do: :validation_failed, else: :blocked

    :telemetry.execute(
      @event_prefix ++ [event],
      %{},
      %{user_id: user_id, reason: inspect(reason)}
    )
  end

  # Records the outcome of a confirmed cancellation.
  defp emit_confirm(user_id, meeting_id, result) do
    measurements = %{user_id: user_id, meeting_id: meeting_id}

    metadata =
      case result do
        {:ok, _cancelled} -> Map.put(measurements, :result, :ok)
        {:error, reason} -> Map.merge(measurements, %{result: :error, reason: inspect(reason)})
      end

    :telemetry.execute(@event_prefix ++ [:confirm], %{}, metadata)
  end

  # The message shown when the refund the host asked for cannot be made.
  defp refund_error_message(:acknowledgement_required),
    do:
      dgettext(
        "dashboard_bookings",
        "Tick the acknowledgement to cancel without refunding the attendee."
      )

  defp refund_error_message(:exceeds_remaining),
    do: dgettext("dashboard_bookings", "Refund amount exceeds the remaining refundable balance.")

  defp refund_error_message(_reason),
    do: dgettext("dashboard_bookings", "Enter a valid partial refund amount.")

  # The message shown once the cancellation has gone through.
  defp success_message({:refund, _cents}),
    do: dgettext("dashboard_bookings", "Meeting cancelled and refund issued.")

  defp success_message(:none),
    do: dgettext("dashboard_bookings", "Meeting cancelled successfully")

  # The message shown when the meeting had been cancelled elsewhere before the
  # host confirmed. A refund the host chose was not issued, so it says so.
  defp already_cancelled_message({:refund, _cents}),
    do:
      dgettext(
        "dashboard_bookings",
        "This booking was already cancelled, so no refund was issued."
      )

  defp already_cancelled_message(:none),
    do: dgettext("dashboard_bookings", "This booking was already cancelled.")
end
