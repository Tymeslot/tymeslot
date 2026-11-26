defmodule Tymeslot.MeetingPayments.Webhooks.SeatCheckoutCompleted do
  @moduledoc """
  `checkout.session.completed` for the payment of a held group seat
  (`Tymeslot.Meetings.SeatHolds`): `Webhooks.CheckoutSessionCompleted`
  resolves the payment, checks the amount and that it is paid, and hands a
  payment owned by a seat hold here.

    * A payment still pending, failed because its hold lapsed first, or
      disputed the instant it was captured: the hold becomes an ordinary
      participant (`CreateGroup.complete_paid_hold/1`) with every job a
      free seat owes, and the payment is recorded paid (a disputed one
      stays `disputed`) and linked to the participant and its meeting, all
      in one transaction. The first paid seat on a slot only holds took
      confirms it, and only then are the slot's calendar event, reminders
      and video room scheduled. A hold still held converts on its own
      meeting even once a planned session's registration has closed, as it
      reserved the seats before the close; a lapsed hold converts wherever
      its slot still has room for all its seats and is open to bookings,
      on a new meeting if nobody holds the slot any more.
    * No room for the seats, a closed registration a lapsed hold meets, a
      hold whose meeting the host cancelled, or a host whose account is
      pending deletion: the payment is recorded paid, the hold released as
      failed, its meeting settled (`SeatRelease.settle_after_hold/1`), and
      a refund of all of it recorded in the same transaction
      (`Refunds.request_remaining_refund/2`). A disputed payment's refund is
      left to its dispute's close.
    * A payment this handler settled already (paid, refunded, or disputed
      after it was paid): a no-op.

  A conversion that fails once it has written has rolled its transaction
  back (a confirmed meeting of the organiser's colliding at the slot has
  aborted it in Postgres), so its refund runs in a fresh one: for a slot
  lost meanwhile, and for a changeset error no retry would change, logged
  as an error, so the money is never kept while Stripe retries.

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
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.MeetingPayments.SeatPaymentQueries
  alias Tymeslot.MeetingPayments.Webhooks.LockedPayment
  alias Tymeslot.MeetingPayments.Webhooks.PaymentCompletion
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Meetings.SeatHoldSchema
  alias Tymeslot.Meetings.UniqueSlot

  # Refusals a conversion can only meet once it has written, so they come
  # back having rolled the transaction back: the slot was taken meanwhile.
  @slot_lost_reasons [
    :time_conflict,
    :booking_limit_reached,
    :already_booked,
    :seat_held,
    :slot_full
  ]

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

  # A conversion that fails has rolled the transaction back, so the payment
  # is settled in a fresh one: refunded when the slot was lost meanwhile, or
  # when the conversion can never succeed (a changeset no retry changes),
  # which would otherwise keep the money while Stripe retries for days.
  defp complete(payment, event_id, object) do
    case LockedPayment.run(payment, event_id, &convert_or_refund(&1, event_id, object)) do
      {:error, reason} = error ->
        case refund_cause(reason) do
          nil ->
            error

          cause ->
            log_conversion_failed(cause, reason, log_meta(payment, event_id))

            LockedPayment.run(
              payment,
              event_id,
              &refund_if_settleable(&1, event_id, object, cause)
            )
        end

      result ->
        result
    end
  end

  defp convert_or_refund(locked, event_id, object) do
    if settleable?(locked),
      do: convert_settleable(locked, event_id, object),
      else: {:ok, :no_op}
  end

  # Refusals decided before anything is written leave the transaction
  # usable, so they are refunded in place; any error has rolled it back and
  # is left to `complete/3`.
  defp convert_settleable(locked, event_id, object) do
    with :ok <- PaymentCompletion.host_accepting(%{organizer_user_id: locked.host_user_id}),
         {:ok, booking} <- CreateGroup.complete_paid_hold(locked.seat_hold_id),
         {:ok, paid} <- PaymentCompletion.mark_paid(locked, event_id, object),
         {:ok, linked} <-
           SeatPaymentQueries.link_seat(paid, %{
             participant_id: booking.participant.id,
             meeting_id: booking.meeting.id
           }) do
      {:ok, {:converted, linked, booking}}
    else
      {:refuse, :host_pending_deletion, _host} ->
        refund(locked, event_id, object, :host_pending_deletion)

      {:refused, :slot_full} ->
        refund(locked, event_id, object, :slot_full)

      {:refused, :hold_not_convertible} ->
        refund_unless_converted(locked, event_id, object)

      {:error, _reason} = error ->
        error
    end
  end

  defp refund_if_settleable(locked, event_id, object, cause) do
    if settleable?(locked),
      do: refund(locked, event_id, object, cause),
      else: {:ok, :no_op}
  end

  # A payment this handler has not settled yet: pending, failed because its
  # hold lapsed first, or disputed the instant it was captured, before its
  # completion landed. A disputed payment this handler did settle carries
  # its `paid_at` (`PaymentCompletion.mark_paid/3` keeps it `disputed`), so
  # a completion redelivered after the dispute books and refunds nothing
  # twice.
  defp settleable?(%BookingPaymentSchema{status: status}) when status in [:pending, :failed],
    do: true

  defp settleable?(%BookingPaymentSchema{status: :disputed, paid_at: nil}), do: true
  defp settleable?(%BookingPaymentSchema{}), do: false

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
        refund(locked, event_id, object, :hold_not_convertible)
    end
  end

  # The payment truly was taken, so it is recorded paid with a refund of all
  # of it (`Refunds.request_remaining_refund/2`, source `:late_payment`),
  # recorded in this same transaction and made by its own job, which also
  # backfills the charge id it needs. A hold still held is released as
  # failed, its meeting locked first. A payment disputed already stays
  # `disputed`, and its refund is recorded failed for the dispute's close
  # (`Webhooks.ChargeDisputeClosed`).
  defp refund(locked, event_id, object, cause) do
    with {:ok, paid} <- PaymentCompletion.mark_paid(locked, event_id, object),
         {:ok, released} <- release_hold(locked.seat_hold_id),
         {:ok, _refund} <- Refunds.request_remaining_refund(paid, :late_payment) do
      {:ok, {:refund_scheduled, paid, released, cause}}
    end
  end

  defp release_hold(hold_id) do
    case SeatHolds.get(hold_id) do
      %SeatHoldSchema{} = hold -> SeatRelease.release_hold(hold, :failed)
      nil -> {:ok, nil}
    end
  end

  # Why a failed conversion is refunded in a fresh transaction, or nil to
  # leave the error for a retry.
  defp refund_cause(reason) do
    cond do
      slot_lost?(reason) -> :slot_lost
      changeset_error?(reason) -> :conversion_failed
      true -> nil
    end
  end

  defp changeset_error?(%Changeset{}), do: true
  defp changeset_error?({:validation_error, %Changeset{}}), do: true
  defp changeset_error?(_reason), do: false

  defp log_conversion_failed(:slot_lost, reason, meta) do
    Logger.info(
      "checkout.session.completed: seat lost while converting, refunding",
      [reason: LogFormat.reason(reason)] ++ meta
    )
  end

  defp log_conversion_failed(:conversion_failed, reason, meta) do
    Logger.error(
      "checkout.session.completed: seat conversion failed for good, refunding",
      [reason: LogFormat.reason(reason)] ++ meta
    )
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

  defp settle_outcome({:ok, {:refund_scheduled, paid, released, cause}}, object, meta) do
    Logger.warning(
      "checkout.session.completed: seat not booked, refund scheduled",
      [cause: cause] ++ meta
    )

    PaymentCompletion.backfill_charge_id(paid, object)
    if released, do: SeatRelease.announce_released(released)

    # The booker paid, so their page is told even when the hold had lapsed
    # already and this release announced nothing on its topic.
    unless match?(%{released?: true}, released),
      do: SeatHolds.broadcast(paid.seat_hold_id, :expired)

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
