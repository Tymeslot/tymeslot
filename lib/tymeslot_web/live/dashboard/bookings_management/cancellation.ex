defmodule TymeslotWeb.Dashboard.BookingsManagement.Cancellation do
  @moduledoc """
  Cancelling a booking from the bookings dashboard and from the calendar's
  preview (`Calendar.BookingActions`): opening the dialog, confirming it
  (with whatever refund the host chose), and the telemetry and user-facing
  copy that go with it, so the two pages act and speak alike.

  The dialog's state lives in the caller's assigns (`dialog_assigns/0`): what
  the cancellation can refund (`t:paid/0`), the refund choice as the host
  last submitted it, and the errors shown beside its fields.

  The reload is passed in rather than reached for: the list or grid belongs
  to the caller, and this module only says when it should be refreshed.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3, update: 3]

  alias Tymeslot.Bookings.Refusal
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingSchema
  alias TymeslotWeb.Dashboard.BookingsManagement.ModalMeeting
  alias TymeslotWeb.Hooks.ModalHook
  alias TymeslotWeb.Live.Shared.Flash

  require Refusal

  require Logger

  @event_prefix [:tymeslot, :dashboard, :meetings, :cancel]

  @typep reload :: (Phoenix.LiveView.Socket.t() -> Phoenix.LiveView.Socket.t())

  @typedoc """
  What a cancellation can refund, as the cancel dialog's assigns hold it: a
  one-to-one booking's payment (nil for a free one), or a group session's
  paid seats (empty for a free one). Never both.
  """
  @type paid :: %{cancel_booking_payment: map() | nil, cancel_seat_payments: [map()]}

  @doc """
  Opens the cancel dialog for the host's meeting `params["id"]`, if `policy`
  allows its cancellation, along with any payment the host took for it, or
  for a group session the seats paid on it (`payments_for/2`), which is what
  offers the refund options. A refusal is flashed.
  """
  @spec show(Phoenix.LiveView.Socket.t(), map(), (MeetingSchema.t() -> :ok | {:error, term()})) ::
          Phoenix.LiveView.Socket.t()
  def show(socket, params, policy) do
    user_id = socket.assigns.current_user.id

    case ModalMeeting.fetch(user_id, params, policy) do
      {:ok, meeting} ->
        open(socket, meeting)

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

  @doc """
  Opens the cancel dialog on `meeting`, which the caller has already looked
  up for the signed-in host and checked may be cancelled: with what it can
  refund (`payments_for/2`) and a blank refund choice.
  """
  @spec open(Phoenix.LiveView.Socket.t(), MeetingSchema.t()) :: Phoenix.LiveView.Socket.t()
  def open(socket, meeting) do
    user_id = socket.assigns.current_user.id
    emit_open(user_id, meeting.id)

    socket
    |> assign(dialog_assigns())
    |> assign(payments_for(meeting, user_id))
    |> ModalHook.show_modal(:cancel_meeting, meeting)
  end

  @doc """
  What cancelling `meeting` can refund the host `user_id` (`t:paid/0`),
  scoped to them: only money they took offers refund options. A group
  session's seats are each their own payment
  (`BookingPayments.seat_payments_for_meeting/2`); any other meeting has at
  most one.
  """
  @spec payments_for(MeetingSchema.t(), integer()) :: paid()
  def payments_for(meeting, user_id) do
    if Meetings.group?(meeting),
      do: %{
        cancel_booking_payment: nil,
        cancel_seat_payments: BookingPayments.seat_payments_for_meeting(meeting.id, user_id)
      },
      else: %{
        cancel_booking_payment: BookingPayments.payment_for_meeting(meeting.id, user_id),
        cancel_seat_payments: []
      }
  end

  defp no_payments, do: %{cancel_booking_payment: nil, cancel_seat_payments: []}

  @doc """
  The dialog's assigns before it opens and after it closes: nothing to
  refund, a blank refund choice (`cancel_refund_form`) and no errors
  (`cancel_refund_error`).
  """
  @spec dialog_assigns() :: map()
  def dialog_assigns,
    do:
      Map.merge(no_payments(), %{
        cancel_refund_error: %{},
        cancel_refund_form: %{choice: "full", amount: "", acknowledged: false}
      })

  @doc "Closes the cancel dialog without cancelling anything."
  @spec hide(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def hide(socket) do
    socket
    |> assign(dialog_assigns())
    |> ModalHook.hide_modal(:cancel_meeting)
  end

  @doc """
  Cancels `meeting` for the signed-in host with the refund the cancel form's
  `params` choose, against what the dialog showed it can refund, and settles
  the dialog, flashing how it went:

    * the booking is cancelled (the refund may still be pending or have been
      declined, or someone else cancelled it first; the message says which):
      the dialog closes and `reload` refreshes the list.
    * the meeting started or ended meanwhile, so nothing changed: the dialog
      closes and `reload` refreshes the stale list.
    * what was paid changed since the dialog opened (`recheck/3`, or the
      cancellation's own read of the paid seats under the meeting's lock), so
      nothing was cancelled: the dialog stays open, showing the payments as
      they now stand and saying so, for the host to choose again.
    * a refund choice that does not validate: the dialog stays open with the
      error beside its field.
    * any other failure: the dialog stays open for another try.

  The host's refund choice is kept whatever the outcome, so a dialog left
  open shows it as they made it.
  """
  @spec confirm(Phoenix.LiveView.Socket.t(), MeetingSchema.t(), map(), reload()) ::
          Phoenix.LiveView.Socket.t()
  def confirm(socket, meeting, params, reload) when is_function(reload, 1) do
    user_id = socket.assigns.current_user.id
    # Kept whatever the outcome: the choice lives in the browser until submit,
    # and a re-render without it would snap the radio back to a full refund.
    socket = assign(socket, :cancel_refund_form, refund_form(params))

    with {:ok, paid} <- recheck(meeting, user_id, paid(socket.assigns)),
         {:ok, refund_action} <- resolve_refund(meeting, paid, params) do
      case cancel_checked(user_id, meeting, paid, refund_action) do
        {:changed, fresh} ->
          payments_changed(socket, fresh)

        {outcome, type, message} ->
          socket
          |> assign(:cancel_refund_error, %{})
          |> Flash.put_flash(type, message)
          |> settle(outcome, reload)
      end
    else
      {:changed, fresh} ->
        payments_changed(socket, fresh)

      # Shown beside the field it is about, rather than as a flash.
      {:error, reason} ->
        assign(socket, :cancel_refund_error, %{
          refund_error_field(reason) => refund_error_message(reason, meeting)
        })
    end
  end

  # The choice stays, but a no-refund acknowledgement was given for the
  # payments as they were, so the host gives it again for these.
  defp payments_changed(socket, fresh) do
    socket
    |> assign(fresh)
    |> update(:cancel_refund_form, &%{&1 | acknowledged: false})
    |> assign(:cancel_refund_error, %{payments: payments_changed_message()})
  end

  @doc """
  Reads what cancelling `meeting` can refund the host `user_id` again, at
  confirm, against `paid`, what the dialog showed when it opened:
  `{:ok, paid}` when the same payments are still owed, `{:changed,
  current}` when one was paid, refunded or released meanwhile. The refund
  is then made against the payments as the dialog showed them, so a balance
  that changed meanwhile is refused rather than silently resized. A refund
  choice is only ever made against payments the host saw: a seat paid after
  the dialog opened would otherwise be left out of a full refund, or kept
  without the host ever acknowledging it.
  """
  @spec recheck(MeetingSchema.t(), integer(), paid()) :: {:ok | :changed, paid()}
  def recheck(meeting, user_id, paid) do
    current = payments_for(meeting, user_id)

    if payment_ids(current) == payment_ids(paid),
      do: {:ok, paid},
      else: {:changed, current}
  end

  defp payment_ids(%{cancel_booking_payment: payment, cancel_seat_payments: seats}),
    do: MapSet.new(for %{id: id} <- [payment | seats], do: id)

  # `{outcome, flash_type, message}`, or `{:changed, fresh}` when a seat was
  # paid or refunded between the recheck and the cancellation's locked read
  # of the seats, so nothing was cancelled.
  defp cancel_checked(user_id, meeting, paid, refund_action) do
    # Read before the cancellation records its refunds, which leave the
    # seats nothing outstanding.
    settled = settled_action(refund_action, paid)

    result =
      Meetings.cancel_meeting_with_refund(meeting, user_id, refund_action,
        seat_payment_ids: Enum.map(paid.cancel_seat_payments, & &1.id)
      )

    emit_confirm(user_id, meeting.id, result)
    outcome(meeting, settled, result)
  end

  # A full refund of a group session refunds only the seats inside the
  # refund window. The cancellation settled exactly the seats the dialog
  # showed (any others roll it back), so when none of them is inside the
  # window nothing was refunded, and the host is told to refund from Stripe.
  defp settled_action(:refund_seats, %{cancel_seat_payments: seats}) do
    case BookingPayments.split_by_refund_window(seats) do
      {[], [_outside | _more]} -> :seats_outside_refund_window
      _refundable_or_none -> :refund_seats
    end
  end

  defp settled_action(refund_action, _paid), do: refund_action

  # What the cancel dialog's assigns say the cancellation can refund.
  defp paid(assigns), do: Map.merge(no_payments(), Map.take(assigns, Map.keys(no_payments())))

  # A group session is settled seat by seat, a one-to-one booking by its one
  # payment.
  defp resolve_refund(meeting, paid, params) do
    if Meetings.group?(meeting),
      do: Meetings.resolve_seat_refund(paid.cancel_seat_payments, params),
      else: Meetings.resolve_cancellation_refund(paid.cancel_booking_payment, params)
  end

  defp outcome(_meeting, refund_action, {:ok, _cancelled}),
    do: {:closed, :info, success_message(refund_action)}

  defp outcome(_meeting, _refund_action, {:error, {:payments_changed, seats}}),
    do: {:changed, %{no_payments() | cancel_seat_payments: seats}}

  # Stripe has not confirmed the refund yet; Tymeslot finishes it, so the
  # host is not sent to Stripe, where a second refund would double it.
  defp outcome(_meeting, _refund_action, {:ok, _cancelled, :refund_pending}),
    do:
      {:closed, :info,
       dgettext(
         "dashboard_bookings_cancel",
         "Meeting cancelled. The refund is being processed and the attendee will be emailed when it goes through."
       )}

  # The meeting is cancelled; Stripe declined the refund.
  defp outcome(_meeting, _refund_action, {:error, {:refund_failed, :refund_failed}}),
    do:
      {:closed, :error,
       dgettext(
         "dashboard_bookings_cancel",
         "Meeting cancelled, but Stripe declined the refund. Check the payment in your Stripe dashboard."
       )}

  # The meeting is cancelled; the payment changed meanwhile, so the refund
  # was refused before Stripe was asked.
  defp outcome(_meeting, _refund_action, {:error, {:refund_failed, reason}}),
    do: {:closed, :error, refund_refused_message(reason)}

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
     dgettext("dashboard_bookings_cancel", "Failed to cancel meeting. Please try again.")}
  end

  # Cancelled: close and reload, because the cancellation did happen even if
  # the refund did not. Refused: close and reload, as the meeting started or
  # ended meanwhile. Otherwise the dialog stays for another try.
  defp settle(socket, outcome, reload) when outcome in [:closed, :refused] do
    socket
    |> assign(:cancelling_meeting, nil)
    |> assign(dialog_assigns())
    |> reload.()
    |> ModalHook.hide_modal(:cancel_meeting)
  end

  defp settle(socket, _kept_open, _reload), do: assign(socket, :cancelling_meeting, nil)

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
        {:ok, _cancelled, :refund_pending} -> Map.put(measurements, :result, :ok)
        {:error, reason} -> Map.merge(measurements, %{result: :error, reason: inspect(reason)})
      end

    :telemetry.execute(@event_prefix ++ [:confirm], %{}, metadata)
  end

  # The refund choice as submitted, to render the dialog with again;
  # anything unrecognised reads as a full refund.
  defp refund_form(params) do
    choice = params["cancel_refund_choice"]
    amount = params["cancel_refund_amount"]

    %{
      choice: if(choice in ["partial", "none"], do: choice, else: "full"),
      amount: if(is_binary(amount), do: amount, else: ""),
      acknowledged: params["cancel_refund_no_refund_ack"] == "true"
    }
  end

  defp refund_error_field(:acknowledgement_required), do: :acknowledgement
  defp refund_error_field(_reason), do: :amount

  # What the cancellation can refund changed between opening the dialog and
  # confirming it: a seat paid, refunded, disputed or given up meanwhile.
  defp payments_changed_message,
    do:
      dgettext(
        "dashboard_bookings_cancel",
        "The payments for this meeting changed while this was open. Check them and choose again."
      )

  # The message shown when the refund the host asked for cannot be made.
  defp refund_error_message(:acknowledgement_required, meeting) do
    if Meetings.group?(meeting),
      do:
        dgettext(
          "dashboard_bookings_cancel",
          "Tick the acknowledgement to cancel without refunding the participants."
        ),
      else:
        dgettext(
          "dashboard_bookings_cancel",
          "Tick the acknowledgement to cancel without refunding the attendee."
        )
  end

  defp refund_error_message(:exceeds_remaining, _meeting),
    do:
      dgettext(
        "dashboard_bookings_cancel",
        "Refund amount exceeds the remaining refundable balance."
      )

  defp refund_error_message(:outside_refund_window, _meeting),
    do:
      dgettext(
        "dashboard_bookings_cancel",
        "No refund can be made: the payment is older than the 60-day refund window. You can refund it from Stripe."
      )

  defp refund_error_message(:under_dispute, _meeting),
    do:
      dgettext(
        "dashboard_bookings_cancel",
        "No refund can be made: the payment is under dispute. Settle the dispute in Stripe first."
      )

  defp refund_error_message(:not_paid, _meeting),
    do: dgettext("dashboard_bookings_cancel", "No refund can be made: the booking was not paid.")

  defp refund_error_message(_reason, _meeting),
    do: dgettext("dashboard_bookings_cancel", "Enter a valid partial refund amount.")

  # The message shown once the cancellation has gone through.
  defp success_message({:refund, _cents}),
    do: dgettext("dashboard_bookings_cancel", "Meeting cancelled and refund issued.")

  # Each paid seat's refund is its own job, so the refunds follow.
  defp success_message(:refund_seats),
    do: dgettext("dashboard_bookings_cancel", "Session cancelled. Refunds are on their way.")

  defp success_message(:seats_outside_refund_window),
    do:
      dgettext(
        "dashboard_bookings_cancel",
        "Session cancelled. No payment could be refunded automatically: they are older than the 60-day refund window. You can refund them from Stripe."
      )

  defp success_message(:none),
    do: dgettext("dashboard_bookings_cancel", "Meeting cancelled successfully")

  defp success_message({:not_refunded, :outside_refund_window}),
    do:
      dgettext(
        "dashboard_bookings_cancel",
        "Cancelled without a refund: the payment is older than the 60-day refund window. You can refund it from Stripe."
      )

  defp success_message({:not_refunded, :under_dispute}),
    do:
      dgettext(
        "dashboard_bookings_cancel",
        "Cancelled without a refund: the payment is under dispute. Settle the dispute in Stripe first."
      )

  defp success_message({:not_refunded, :not_paid}),
    do:
      dgettext(
        "dashboard_bookings_cancel",
        "Cancelled without a refund: the booking was not paid."
      )

  # A refund the payment no longer allowed once the meeting was cancelled.
  defp refund_refused_message(reason)
       when reason in [:outside_refund_window, :under_dispute, :not_paid],
       do: success_message({:not_refunded, reason})

  defp refund_refused_message(_balance_changed),
    do:
      dgettext(
        "dashboard_bookings_cancel",
        "Cancelled without a refund: the payment's refundable balance changed meanwhile. Check it on the payments page."
      )

  # The message shown when the meeting had been cancelled elsewhere before the
  # host confirmed. A refund the host chose was not issued, so it says so.
  defp already_cancelled_message(refund_action) do
    if refunding?(refund_action),
      do:
        dgettext(
          "dashboard_bookings_cancel",
          "This booking was already cancelled, so no refund was issued."
        ),
      else: dgettext("dashboard_bookings_cancel", "This booking was already cancelled.")
  end

  defp refunding?({:refund, _cents}), do: true
  defp refunding?(:refund_seats), do: true
  defp refunding?(_no_refund), do: false
end
