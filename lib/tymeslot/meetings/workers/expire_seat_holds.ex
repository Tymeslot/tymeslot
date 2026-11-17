defmodule Tymeslot.Meetings.Workers.ExpireSeatHolds do
  @moduledoc """
  Cron sweeper that settles paid seat holds (`Tymeslot.Meetings.SeatHolds`)
  whose payment outcome never reached them, so a lost Stripe webhook never
  keeps a slot's seats taken.

  A hold outlives its Checkout session by a short grace, so the session's
  own expiry webhook normally releases it first. A hold still `held` five
  minutes past its `expires_at` is settled here:

    * its payment has a Checkout session: the session is polled and its
      completion or expiry replayed through the webhook handlers
      (`ReconcileAwaitingPayments.reconcile/1`); a session Stripe still
      reports open is skipped, and picked up again by a later run;
    * no session (the checkout never opened) or no payment at all: the
      payment, if any, is failed and the hold released as `:failed`, its
      meeting settled (`SeatRelease.release_unpaid_hold/1`).

  Runs every five minutes (configured in the Oban crontab). One hold that
  cannot be settled is logged and counted, and the rest are still swept.
  `@batch_limit` bounds one run; a backlog is worked through over the next
  ones, the longest overdue first.
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

  @grace_seconds 5 * 60
  @batch_limit 200

  @type sweep_result :: %{
          released: non_neg_integer(),
          reconciled: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer()
        }

  @impl Oban.Worker
  def perform(_job) do
    cutoff =
      Clock.utc_now()
      |> DateTime.add(-@grace_seconds, :second)
      |> DateTime.truncate(:second)

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
    case BookingPayments.payment_for_seat_hold(hold.id) do
      %BookingPaymentSchema{status: :pending, stripe_checkout_session_id: session_id} = payment
      when is_binary(session_id) ->
        reconcile_tally(ReconcileAwaitingPayments.reconcile(payment))

      _no_session ->
        release(hold)
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
