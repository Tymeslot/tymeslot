defmodule Tymeslot.MeetingPayments.Webhooks.LockedPayment do
  @moduledoc """
  Runs one webhook's change to a `booking_payment` against the row as it
  stands under its row lock, never against the copy the handler resolved.

  Handlers resolve their row (`PaymentLookup`) before any transaction opens,
  and several different events move the same row: Stripe's
  `checkout.session.completed`, the reconciler's replay of it under its own
  event id, `charge.refunded`, `charge.dispute.*`. Deciding from the resolved
  copy lets one handler write over what another committed in between. Here
  the row is locked (`SELECT … FOR UPDATE`) inside the transaction, the
  `last_event_id` replay guard is checked again on the locked row, and only
  then is the change decided, so concurrent handlers of one payment run one
  after the other and each sees what the previous one committed.

  Lock order: the organiser's schedule lock first (taken only by a late
  completion recovering an expired booking, through
  `Scheduling.reinstate_with_conflict_check/2`), then the payment row, then
  the meeting row, as in every other writer of both
  (`ConnectAccounts.disconnect/1`, `FailAndExpire`).

  This lock is the one concurrency mechanism for a webhook's status change;
  there is deliberately no compare-and-set alternative beside it. The writes
  outside it (`ChargeBackfill` filling `stripe_charge_id`,
  `CheckoutSessions` attaching the session and intent ids to the row it has
  just created) touch only those Stripe ids. No transition decides on them,
  every writer sets them to the same value Stripe assigned, and Ecto writes
  only the fields a changeset changes, so a stale copy cannot undo a status.
  """

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.Repo

  @doc """
  Locks `payment`'s row and calls `fun` with the locked copy, in a
  transaction. `fun` returns `{:ok, value}` to commit or `{:error, reason}` to
  roll back.

  Returns `{:ok, value}`, `{:ok, :idempotent_replay}` when the locked row
  already carries `event_id`, or `{:error, reason}`. Called inside an outer
  transaction, it joins that one.
  """
  @spec run(
          BookingPaymentSchema.t(),
          String.t(),
          (BookingPaymentSchema.t() -> {:ok, value} | {:error, term()})
        ) :: {:ok, value | :idempotent_replay} | {:error, term()}
        when value: term()
  def run(%BookingPaymentSchema{id: id}, event_id, fun) do
    Repo.transaction(fn ->
      case BookingPaymentQueries.get_for_update(id) do
        {:ok, %BookingPaymentSchema{last_event_id: ^event_id}} ->
          :idempotent_replay

        {:ok, locked} ->
          case fun.(locked) do
            {:ok, value} -> value
            {:error, reason} -> Repo.rollback(reason)
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end
end
