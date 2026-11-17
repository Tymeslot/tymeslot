defmodule Tymeslot.MeetingPayments.Workers.SeriesHostRefund do
  @moduledoc """
  Refunds `amount_cents` of a series payment on behalf of its host, after
  the host cancelled the sessions of the series still to come
  (`Tymeslot.BookingSeries.Cancel`).

  The cancellation inserts this job in its own transaction, so the refund is
  recorded with the sessions it pays back for, or not at all, and the Stripe
  call never runs inside that transaction. Each attempt refunds through
  `Refunds.issue_host_refund/5`, which re-checks ownership, the refusals and
  the remaining balance under the payment's row lock. Its Stripe idempotency
  key is the job's own (`series_refund:<job id>`), the same on every
  attempt, so an attempt whose refund Stripe accepted but whose transaction
  rolled back is answered with that same refund on retry, and recorded
  then, even when another refund of the payment landed in between (a key
  derived from the payment's refunded total would have changed with it,
  and refunded twice). That holds when the `charge.refunded` webhook
  recorded the refund in between, too: the refund is recorded as Stripe's
  refunded total for the charge, so the replay adds nothing, and an amount
  the balance no longer covers is put to Stripe under the key rather than
  refused (`Refunds.issue_host_refund/5`). The retries end within about four hours
  (`backoff/1`), well inside the 24 hours Stripe keeps a key.

  Whether the refund is already made is the job's own record, never the
  payment's running total: other refunds of the same payment (the host
  refunding one session as they cancel it) can land between the
  cancellation and the job, so a total grown past `refunded_before_cents`
  says nothing about this job. The refund is claimed for the job
  (`DeliveryClaims.claim/2`) in the transaction that records it, so the
  claim commits with the refund or rolls back with it, and a run that
  finds the claim held (an earlier attempt, or the same job rescued after
  its node stopped, recorded the refund and failed only afterwards) treats
  the refund as made. `refunded_before_cents` only names the refund for
  the job's uniqueness and the host's failure email.

  A refund no retry can make (outside the refund window, under dispute,
  not paid, more than remains) is discarded at once; any other failure is
  retried over about four hours. Neither declares itself an expected
  outcome, so ErrorTracker records every failed attempt and the discard
  (`ErrorTracking.ObanOutcomes`), and a new error raises its admin alert.

  When it gives up on a refund (discarded as one no retry can make, or
  failed on its last attempt, by an error, a raise or an exit), the host is
  emailed
  (`Tymeslot.Workers.SendSeriesRefundFailed`): the series payment appears
  on their outstanding-refunds list only once none of its sessions goes
  ahead, so the email is how they learn the money is still theirs to
  return. No email goes out when the payment is gone or the money was
  already refunded.
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 10,
    unique: [
      keys: [:booking_payment_id, :refunded_before_cents, :amount_cents],
      states: :all,
      period: :infinity
    ]

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.ChargeBackfill
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.Repo
  alias Tymeslot.Workers.Backoff
  alias Tymeslot.Workers.DeliveryClaims
  alias Tymeslot.Workers.SendSeriesRefundFailed

  @claim "series_host_refund"

  @base_backoff_seconds 60
  @max_backoff_seconds 3_600

  @unretryable [
    :not_found,
    :not_paid,
    :outside_refund_window,
    :under_dispute,
    :already_refunded,
    :invalid_amount
  ]

  @doc """
  Builds the job refunding `amount_cents` of `payment` for `host_user_id`.
  Insert it in the transaction that cancels the sessions it pays back for.
  """
  @spec new_for(BookingPaymentSchema.t(), integer(), pos_integer()) :: Oban.Job.changeset()
  def new_for(%BookingPaymentSchema{} = payment, host_user_id, amount_cents)
      when is_integer(host_user_id) and is_integer(amount_cents) and amount_cents > 0 do
    new(%{
      booking_payment_id: payment.id,
      host_user_id: host_user_id,
      amount_cents: amount_cents,
      refunded_before_cents: payment.refunded_amount_cents
    })
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    case refund(job.id, args) do
      :ok ->
        :ok

      {:error, reason} when reason in @unretryable ->
        log_failure(job, args, reason)
        tell_host(args, reason)
        {:discard, reason}

      {:error, reason} ->
        log_failure(job, args, reason)
        if job.attempt >= job.max_attempts, do: tell_host(args, reason)
        {:error, reason}
    end
  end

  # The refund will not be made: the host is told, unless there is no
  # payment to tell them about or its money was already returned.
  defp tell_host(_args, reason) when reason in [:not_found, :already_refunded], do: :ok

  defp tell_host(args, reason) do
    email =
      SendSeriesRefundFailed.new_for(
        args["booking_payment_id"],
        args["amount_cents"],
        args["refunded_before_cents"],
        reason
      )

    case Oban.insert(email) do
      {:ok, _job} ->
        :ok

      {:error, error} ->
        Logger.error("Could not queue the series refund failure email",
          booking_payment_id: args["booking_payment_id"],
          reason: LogFormat.reason(error)
        )
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}),
    do: Backoff.exponential(attempt, @base_backoff_seconds, @max_backoff_seconds)

  # A raise (a dropped connection, say) or an exit (a call that timed out)
  # is an attempt failing like any other, so the last one still tells the
  # host. The worker sets no Oban timeout, which would kill the attempt
  # past any rescue.
  defp refund(job_id, %{
         "booking_payment_id" => id,
         "host_user_id" => host_user_id,
         "amount_cents" => amount
       }) do
    with %BookingPaymentSchema{} = payment <- MeetingPayments.get_payment(id),
         false <- DeliveryClaims.claimed?(job_id, @claim),
         :ok <- Refunds.refusal(payment),
         {:ok, _payment} <- ensure_charge(payment),
         {:ok, _refunded} <- refund_once(job_id, id, host_user_id, amount) do
      :ok
    else
      nil -> {:error, :not_found}
      true -> :ok
      {:error, _reason} = error -> error
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason when kind in [:exit, :throw] -> {:error, {kind, reason}}
  end

  # A job with no id (built by hand) cannot run twice, so has nothing to
  # claim and no key of its own: it refunds under the derived key.
  # Otherwise the claim and the refund commit together, and a run racing
  # for the claim waits on it, then finds the refund made.
  defp refund_once(nil, id, host_user_id, amount),
    do: Refunds.issue_host_refund(id, host_user_id, amount)

  defp refund_once(job_id, id, host_user_id, amount) do
    Repo.transaction(fn ->
      with :claimed <- DeliveryClaims.claim(job_id, @claim),
           {:ok, refunded} <-
             Refunds.issue_host_refund(id, host_user_id, amount, nil,
               idempotency_key: "series_refund:#{job_id}"
             ) do
        refunded
      else
        :already_claimed -> :already_made
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp ensure_charge(%{stripe_charge_id: charge} = payment)
       when is_binary(charge) and charge != "",
       do: {:ok, payment}

  defp ensure_charge(payment),
    do: ChargeBackfill.backfill(payment, payment.stripe_payment_intent_id)

  defp log_failure(job, args, reason) do
    Logger.error("Series host refund failed",
      booking_payment_id: args["booking_payment_id"],
      amount_cents: args["amount_cents"],
      attempt: job.attempt,
      reason: LogFormat.reason(reason)
    )
  end
end
