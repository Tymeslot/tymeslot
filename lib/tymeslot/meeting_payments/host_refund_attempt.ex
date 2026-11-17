defmodule Tymeslot.MeetingPayments.HostRefundAttempt do
  @moduledoc """
  One attempt at a refund a host's cancellation owes, run by the jobs a
  cancellation inserts in its own transaction:
  `Tymeslot.MeetingPayments.Workers.SeriesHostRefund` (the remaining
  sessions of a series) and `Tymeslot.MeetingPayments.Workers.GroupCancelRefund`
  (each paid seat of a cancelled group session). Both share this body, so
  the refund rule, the claim and the failure email cannot drift apart.

  Each attempt refunds through `Refunds.issue_host_refund/5`, which
  re-checks ownership, the refusals and the remaining balance under the
  payment's row lock. Its Stripe idempotency key is the job's own
  (`<prefix>:<job id>`), the same on every attempt, so an attempt whose
  refund Stripe accepted but whose transaction rolled back is answered with
  that same refund on retry, and recorded then, even when another refund of
  the payment landed in between (a key derived from the payment's refunded
  total would have changed with it, and refunded twice). The retries end
  within about four hours (`backoff/1`), well inside the 24 hours Stripe
  keeps a key.

  Whether the refund is already made is the job's own record, never the
  payment's running total: other refunds of the same payment can land
  between the cancellation and the job, so a total grown past
  `refunded_before_cents` says nothing about this job. The refund is
  claimed for the job (`DeliveryClaims.claim/2`) in the transaction that
  records it, so the claim commits with the refund or rolls back with it,
  and a run that finds the claim held (an earlier attempt, or the same job
  rescued after its node stopped, recorded the refund and failed only
  afterwards) treats the refund as made. `refunded_before_cents` only names
  the refund for the job's uniqueness and the host's failure email.

  A refund no retry can make (`unretryable/0`: outside the refund window,
  under dispute, not paid, more than remains) is discarded at once; any
  other failure is retried. Neither declares itself an expected outcome,
  so ErrorTracker records every failed attempt and the discard
  (`ErrorTracking.ObanOutcomes`), and a new error raises its admin alert.

  When it gives up on a refund (discarded as one no retry can make, or
  failed on its last attempt, by an error, a raise or an exit), the host is
  emailed (`Tymeslot.Workers.SendSeriesRefundFailed`), worded for the
  cancellation the job came from. No email goes out when the payment is
  gone or the money was already refunded.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.ChargeBackfill
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.Repo
  alias Tymeslot.Workers.Backoff
  alias Tymeslot.Workers.DeliveryClaims
  alias Tymeslot.Workers.SendSeriesRefundFailed

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

  @typedoc """
  What tells one job's refunds apart from another's:

    * `:claim` - the `DeliveryClaims` name the refund is claimed under.
    * `:key_prefix` - the prefix of the Stripe idempotency key.
    * `:log_message` - logged on every failed attempt.
    * `:email` - options for `SendSeriesRefundFailed.new_for/5`.
  """
  @type opts :: [
          claim: String.t(),
          key_prefix: String.t(),
          log_message: String.t(),
          email: keyword()
        ]

  @doc "The refund failures no retry can turn round."
  @spec unretryable() :: [atom()]
  def unretryable, do: @unretryable

  @doc """
  Runs `job` (args `booking_payment_id`, `host_user_id`, `amount_cents`,
  `refunded_before_cents`) as one attempt, returning what the worker's
  `perform/1` returns: `:ok`, `{:discard, reason}` for a refund no retry can
  make, or `{:error, reason}` to retry.
  """
  @spec perform(Oban.Job.t(), opts()) :: :ok | {:discard, term()} | {:error, term()}
  def perform(%Oban.Job{args: args} = job, opts) do
    case run(job, opts) do
      :ok ->
        :ok

      {:error, reason} when reason in @unretryable ->
        log_failure(job, reason, opts)
        tell_host(args, reason, opts)
        {:discard, reason}

      {:error, reason} ->
        log_failure(job, reason, opts)
        if job.attempt >= job.max_attempts, do: tell_host(args, reason, opts)
        {:error, reason}
    end
  end

  @doc "The retry delay after `attempt`: exponential, capped at an hour."
  @spec backoff(pos_integer()) :: pos_integer()
  def backoff(attempt),
    do: Backoff.exponential(attempt, @base_backoff_seconds, @max_backoff_seconds)

  # A raise (a dropped connection, say) or an exit (a call that timed out)
  # is an attempt failing like any other, so the last one still tells the
  # host. The workers set no Oban timeout, which would kill the attempt
  # past any rescue.
  defp run(%Oban.Job{id: job_id, args: args}, opts) do
    %{"booking_payment_id" => id, "host_user_id" => host_user_id, "amount_cents" => amount} =
      args

    with %BookingPaymentSchema{} = payment <- BookingPayments.get_payment(id),
         false <- DeliveryClaims.claimed?(job_id, opts[:claim]),
         :ok <- Refunds.refusal(payment),
         {:ok, _payment} <- ensure_charge(payment),
         {:ok, _refunded} <- refund_once(job_id, id, host_user_id, amount, opts) do
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
  defp refund_once(nil, id, host_user_id, amount, _opts),
    do: Refunds.issue_host_refund(id, host_user_id, amount)

  defp refund_once(job_id, id, host_user_id, amount, opts) do
    Repo.transaction(fn ->
      with :claimed <- DeliveryClaims.claim(job_id, opts[:claim]),
           {:ok, refunded} <-
             Refunds.issue_host_refund(id, host_user_id, amount, nil,
               idempotency_key: "#{opts[:key_prefix]}:#{job_id}"
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

  # The refund will not be made: the host is told, unless there is no
  # payment to tell them about or its money was already returned.
  defp tell_host(_args, reason, _opts) when reason in [:not_found, :already_refunded], do: :ok

  defp tell_host(args, reason, opts) do
    email =
      SendSeriesRefundFailed.new_for(
        args["booking_payment_id"],
        args["amount_cents"],
        args["refunded_before_cents"],
        reason,
        Keyword.get(opts, :email, [])
      )

    case Oban.insert(email) do
      {:ok, _job} ->
        :ok

      {:error, error} ->
        Logger.error("Could not queue the refund failure email",
          booking_payment_id: args["booking_payment_id"],
          reason: LogFormat.reason(error)
        )
    end
  end

  defp log_failure(job, reason, opts) do
    Logger.error(opts[:log_message],
      booking_payment_id: job.args["booking_payment_id"],
      amount_cents: job.args["amount_cents"],
      attempt: job.attempt,
      reason: LogFormat.reason(reason)
    )
  end
end
