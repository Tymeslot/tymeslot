defmodule Tymeslot.Meetings.Workers.ExpireSeatHolds do
  @moduledoc """
  Cron sweeper that settles paid seat holds (`Tymeslot.Meetings.SeatHolds`)
  whose payment outcome never reached them, so a lost Stripe webhook never
  keeps a slot's seats taken.

  A hold outlives its Checkout session by a short grace, so the session's
  own expiry webhook normally releases it first. A hold still `held` five
  minutes past its `expires_at` is settled here:

    * its payment is pending with a Checkout session: the session is polled
      and its completion or expiry replayed through the webhook handlers
      (`ReconcileAwaitingPayments.reconcile/1`); a session Stripe still
      reports open is skipped, and picked up again by a later run;
    * no payment at all, a pending one with no session (the checkout never
      opened), or a failed one: the payment, if pending, is failed and the
      hold released as `:failed`, its meeting settled
      (`SeatRelease.release_unpaid_hold/1`);
    * a payment disputed before its completion reached the hold (no
      `paid_at`) with a Checkout session: reconciled as a pending one is;
    * a payment paid, disputed or refunded beside a hold still held: a
      hold converts with its payment, so this is a broken invariant. It is
      logged as an error and counted, never released, so a paid seat is
      not given away.

  Runs every five minutes (configured in the Oban crontab). One hold that
  cannot be settled is logged and counted, and the rest are still swept.
  `@batch_limit` bounds one run; a hold a run leaves held is marked swept
  (`SeatHolds.mark_swept/1`) and goes behind the others, so a backlog of
  sessions Stripe reports open cannot starve the rest.
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 1,
    unique: [period: 240]

  require Logger

  alias Tymeslot.Bookings.SeatRelease
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.Workers.ReconcileAwaitingPayments
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Meetings.SeatHoldSchema

  @batch_limit 200

  @type sweep_result :: %{
          released: non_neg_integer(),
          reconciled: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer()
        }

  @impl Oban.Worker
  def perform(_job) do
    cutoff = SeatHolds.overdue_cutoff(Clock.utc_now())

    result =
      cutoff
      |> SeatHolds.list_overdue(@batch_limit)
      |> Enum.reduce(%{released: 0, reconciled: 0, skipped: 0, errors: 0}, fn hold, acc ->
        Map.update!(acc, settle(hold), &(&1 + 1))
      end)

    Logger.info("ExpireSeatHolds sweep complete",
      released: result.released,
      reconciled: result.reconciled,
      skipped: result.skipped,
      errors: result.errors
    )

    {:ok, result}
  end

  defp settle(hold) do
    outcome = settle_payment(hold, BookingPayments.payment_for_seat_hold(hold.id))
    if outcome != :released, do: SeatHolds.mark_swept(hold.id)
    outcome
  end

  defp settle_payment(
         _hold,
         %BookingPaymentSchema{status: :pending, stripe_checkout_session_id: id} = payment
       )
       when is_binary(id),
       do: reconcile_tally(ReconcileAwaitingPayments.reconcile(payment))

  defp settle_payment(hold, nil), do: release(hold)

  defp settle_payment(hold, %BookingPaymentSchema{
         status: :pending,
         stripe_checkout_session_id: nil
       }),
       do: release(hold)

  defp settle_payment(hold, %BookingPaymentSchema{status: :failed}), do: release(hold)

  # Disputed before its completion reached the hold: Stripe took the
  # payment, so its session is replayed as for a pending one, and the
  # completion handler books the seat or refunds it.
  defp settle_payment(
         _hold,
         %BookingPaymentSchema{status: :disputed, paid_at: nil, stripe_checkout_session_id: id} =
           payment
       )
       when is_binary(id),
       do: reconcile_tally(ReconcileAwaitingPayments.reconcile(payment))

  # Read unlocked, so the hold may have converted with its payment since it
  # was listed; only one still held beside a settled payment is wrong.
  defp settle_payment(hold, %BookingPaymentSchema{status: status} = payment) do
    case SeatHolds.get(hold.id) do
      %SeatHoldSchema{status: :held} ->
        Logger.error("ExpireSeatHolds found a seat hold still held beside a settled payment",
          seat_hold_id: hold.id,
          payment_id: payment.id,
          status: status
        )

        :errors

      _settled ->
        :skipped
    end
  end

  defp reconcile_tally(:reconciled), do: :reconciled
  defp reconcile_tally(:skipped), do: :skipped
  defp reconcile_tally(:error), do: :errors

  defp release(hold) do
    case SeatRelease.release_unpaid_hold(hold) do
      {:ok, _released} ->
        :released

      {:error, reason} ->
        Logger.error("ExpireSeatHolds could not release a seat hold",
          seat_hold_id: hold.id,
          reason: LogFormat.reason(reason)
        )

        :errors
    end
  end
end
