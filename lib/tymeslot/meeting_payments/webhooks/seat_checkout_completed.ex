defmodule Tymeslot.MeetingPayments.Webhooks.SeatCheckoutCompleted do
  @moduledoc """
  `checkout.session.completed` for the payment of a held group seat
  (`Tymeslot.Meetings.SeatHolds`): `Webhooks.CheckoutSessionCompleted`
  resolves the payment, checks the amount and that it is paid, and hands a
  payment owned by a seat hold here.

    * A payment still pending, or failed because its hold lapsed first: the
      hold becomes an ordinary participant (`CreateGroup.complete_paid_hold/2`)
      with every job a free seat owes, and the payment is recorded paid and
      linked to the participant and its meeting, all in one transaction.
      The first paid seat on a slot only holds took confirms it, and only
      then are the slot's calendar event, reminders and video room
      scheduled. A lapsed hold converts wherever its slot still has room
      for all its seats, on a new meeting if nobody holds the slot any more.
    * No room for the seats, a hold whose meeting the host cancelled, or a
      host whose account is pending deletion: the payment is recorded paid,
      the hold released as failed, its meeting settled
      (`SeatRelease.settle_after_hold/1`), and the payment refunded in full
      by `Workers.RefundLatePayment`, inserted in the same transaction.
    * A payment already paid, refunded or disputed: a no-op.

  A conversion that collides with a meeting of the organiser's confirmed at
  the slot meanwhile (the confirmed-slot unique index) has aborted the
  transaction in Postgres, so its refund runs in a fresh one.

  Locks: the payment row (`LockedPayment`), then the organiser's schedule
  lock, the hold's meeting and the hold. The booker's page waits on the
  hold's topic (`SeatHolds.topic/1`), never the meeting's, which belongs to
  the meeting's own payment.
  """

  require Logger

  alias Ecto.Changeset
  alias Tymeslot.Bookings.Activation
  alias Tymeslot.Bookings.CreateGroup
  alias Tymeslot.Bookings.SeatEffects
  alias Tymeslot.Bookings.SeatRelease
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.Webhooks.LockedPayment
  alias Tymeslot.MeetingPayments.Webhooks.PaymentCompletion
  alias Tymeslot.MeetingPayments.Workers.RefundLatePayment
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Meetings.SeatHoldSchema
  alias Tymeslot.Meetings.UniqueSlot

  @settleable [:pending, :failed]

  # Refusals a conversion can only meet once it has written, so they come
  # back having rolled the transaction back: the slot was taken meanwhile.
  @slot_lost_reasons [:time_conflict, :booking_limit_reached, :already_booked, :slot_full]

  @doc """
  Completes the seat payment `payment` (a paid checkout session `object`,
  delivered as `event_id`). Returns `:ok`, or `{:error, reason}` for Stripe
  (or the reconciler) to try again.
  """
  @spec run(BookingPaymentSchema.t(), String.t(), map()) :: :ok | {:error, term()}
  def run(%BookingPaymentSchema{seat_hold_id: hold_id} = payment, event_id, object)
      when is_binary(hold_id) do
    payment
    |> complete(event_id, object)
    |> settle_outcome(object, log_meta(payment, event_id))
  end

  defp complete(payment, event_id, object) do
    case LockedPayment.run(payment, event_id, &convert_or_refund(&1, event_id, object)) do
      {:error, reason} = error ->
        if slot_lost?(reason),
          do: LockedPayment.run(payment, event_id, &refund_if_settleable(&1, event_id, object)),
          else: error

      result ->
        result
    end
  end

  defp convert_or_refund(%BookingPaymentSchema{status: status} = locked, event_id, object)
       when status in @settleable do
    with :ok <- PaymentCompletion.host_accepting(%{organizer_user_id: locked.host_user_id}),
         {:ok, booking} <- CreateGroup.complete_paid_hold(locked.seat_hold_id),
         {:ok, paid} <- PaymentCompletion.mark_paid(locked, event_id, object),
         {:ok, linked} <-
           BookingPaymentQueries.link_seat(paid, %{
             participant_id: booking.participant.id,
             meeting_id: booking.meeting.id
           }) do
      {:ok, {:converted, linked, booking}}
    else
      {:refuse, :host_pending_deletion, _host} -> refund(locked, event_id, object)
      {:error, :slot_full} -> refund(locked, event_id, object)
      {:error, :hold_not_convertible} -> refund_unless_converted(locked, event_id, object)
      {:error, _reason} = error -> error
    end
  end

  defp convert_or_refund(_settled, _event_id, _object), do: {:ok, :no_op}

  defp refund_if_settleable(%BookingPaymentSchema{status: status} = locked, event_id, object)
       when status in @settleable,
       do: refund(locked, event_id, object)

  defp refund_if_settleable(_settled, _event_id, _object), do: {:ok, :no_op}

  # A hold converts only with its payment, in one transaction, so a
  # converted hold beside a payment still unsettled is a broken invariant,
  # not a payment to refund.
  defp refund_unless_converted(locked, event_id, object) do
    case SeatHolds.get(locked.seat_hold_id) do
      %SeatHoldSchema{status: :converted} ->
        Logger.error("checkout.session.completed: seat hold converted but its payment unsettled",
          payment_id: locked.id,
          event_id: event_id
        )

        {:ok, :no_op}

      _refundable ->
        refund(locked, event_id, object)
    end
  end

  # The payment truly was taken, so it is recorded paid and refunded in full
  # by `RefundLatePayment`, inserted in this same transaction, which also
  # backfills the charge id it needs. A hold still held is released as
  # failed, its meeting locked first.
  defp refund(locked, event_id, object) do
    with {:ok, paid} <- PaymentCompletion.mark_paid(locked, event_id, object),
         {:ok, released} <- release_hold(locked.seat_hold_id),
         {:ok, _job} <- Oban.insert(RefundLatePayment.new_for(paid.id)) do
      {:ok, {:refund_scheduled, paid, released}}
    end
  end

  defp release_hold(hold_id) do
    case SeatHolds.get(hold_id) do
      %SeatHoldSchema{} = hold -> SeatRelease.release_hold(hold, :failed)
      nil -> {:ok, nil}
    end
  end

  defp slot_lost?(reason) when reason in @slot_lost_reasons, do: true
  defp slot_lost?({:validation_error, %Changeset{} = changeset}), do: slot_lost?(changeset)

  defp slot_lost?(%Changeset{} = changeset),
    do: UniqueSlot.violation?(changeset) or ParticipantSchema.duplicate_seat?(changeset)

  defp slot_lost?(_reason), do: false

  defp settle_outcome({:ok, {:converted, paid, booking}}, object, _meta) do
    PaymentCompletion.backfill_charge_id(paid, object)
    PaymentCompletion.emit_payment_succeeded(paid, booking.meeting)
    :ok = Activation.after_commit(booking.on_booked_result)
    SeatEffects.broadcast_and_invalidate(booking.meeting)
    SeatHolds.broadcast(paid.seat_hold_id, {:paid, booking.participant.id})
    :ok
  end

  defp settle_outcome({:ok, {:refund_scheduled, paid, released}}, object, meta) do
    Logger.warning(
      "checkout.session.completed: seat not booked (no room, meeting cancelled or host leaving), refund scheduled",
      meta
    )

    PaymentCompletion.backfill_charge_id(paid, object)

    if released,
      do: SeatRelease.announce_released(released),
      else: SeatHolds.broadcast(paid.seat_hold_id, :expired)

    :ok
  end

  defp settle_outcome({:ok, outcome}, _object, _meta)
       when outcome in [:no_op, :idempotent_replay],
       do: :ok

  defp settle_outcome({:error, reason} = error, _object, meta) do
    Logger.error(
      "checkout.session.completed handler failed for a seat",
      [reason: LogFormat.reason(reason)] ++ meta
    )

    error
  end

  defp log_meta(payment, event_id),
    do: [seat_hold_id: payment.seat_hold_id, payment_id: payment.id, event_id: event_id]
end
