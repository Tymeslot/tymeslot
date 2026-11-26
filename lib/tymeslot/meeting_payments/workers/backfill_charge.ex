defmodule Tymeslot.MeetingPayments.Workers.BackfillCharge do
  @moduledoc """
  Records a paid booking's Stripe charge id when `checkout.session.completed`
  could not.

  The completion handler reads the charge from the payment intent once the
  payment is committed (`ChargeBackfill`). When that read fails, the webhook
  is still acknowledged, since the booking is confirmed, and the read is
  handed to this job instead. Until the charge id is recorded, a host refund
  of the payment cannot be made, and charge events find the row only by its
  payment intent.

  An intent with no charge yet (normal for delayed payment methods) and a
  Stripe failure a later attempt can get past are retried, over about four
  hours (`backoff/1`); an intent Stripe refuses for good, or a charge id
  the row refuses, cancels the job.
  The last failed attempt is logged as an error and raises no alert: a
  refund backfills the charge id again before it is made
  (`RefundExecutor`).

  At most one job waits per payment: a redelivered completion while one is
  pending inserts nothing.
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 12,
    unique: [keys: [:booking_payment_id], states: :incomplete, period: :infinity]

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Stripe.Error, as: StripeError

  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.ChargeBackfill
  alias Tymeslot.Workers.Backoff

  # Thirty seconds, doubling, capped at half an hour: eleven waits between
  # twelve attempts add up to 14_130 seconds (3h55m).
  @base_backoff_seconds 30
  @max_backoff_seconds 1_800

  @doc """
  Hands the charge id backfill of `payment` to a job reading `intent_id`.
  A failed insert is logged; the charge id is then backfilled on demand by
  the refund paths.
  """
  @spec enqueue(BookingPaymentSchema.t(), payment_intent_id :: String.t()) :: :ok
  def enqueue(%BookingPaymentSchema{id: id}, intent_id) when is_binary(intent_id) do
    case Oban.insert(new(%{booking_payment_id: id, payment_intent_id: intent_id})) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("Charge id backfill could not be scheduled",
          booking_payment_id: id,
          reason: LogFormat.reason(reason)
        )

        :ok
    end
  end

  @impl Oban.Worker
  def perform(
        %Oban.Job{args: %{"booking_payment_id" => id, "payment_intent_id" => intent_id}} = job
      ) do
    case BookingPayments.get_payment(id) do
      nil ->
        {:discard, :not_found}

      %BookingPaymentSchema{stripe_charge_id: charge_id} when is_binary(charge_id) ->
        :ok

      payment ->
        payment |> ChargeBackfill.backfill(intent_id) |> outcome(id) |> log_if_last(job)
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}),
    do: Backoff.exponential(attempt, @base_backoff_seconds, @max_backoff_seconds)

  defp outcome({:ok, _payment}, _id), do: :ok
  defp outcome({:error, :missing_payment_intent}, _id), do: {:cancel, :missing_payment_intent}

  defp outcome({:error, %StripeError{} = error}, id) do
    if StripeError.retryable?(error) do
      {:error, error}
    else
      Logger.warning("Charge id backfill refused by Stripe, job cancelled",
        booking_payment_id: id,
        operation: error.operation,
        status: error.status,
        code: error.code,
        request_id: error.request_id
      )

      {:cancel, error}
    end
  end

  # Stripe gave the charge id but the row refused it (another payment holds
  # the same charge id, say); every retry would read it again only to fail
  # the same way.
  defp outcome({:error, %Ecto.Changeset{} = changeset}, id) do
    Logger.error("Charge id backfill could not store the charge id, job cancelled",
      booking_payment_id: id,
      reason: LogFormat.reason(changeset)
    )

    {:cancel, changeset}
  end

  defp outcome({:error, _reason} = error, _id), do: error

  defp log_if_last(
         {:error, reason} = result,
         %Oban.Job{attempt: attempt, max_attempts: max} = job
       )
       when attempt >= max do
    Logger.error("Charge id backfill gave up; the refund paths backfill it on demand",
      booking_payment_id: job.args["booking_payment_id"],
      reason: LogFormat.reason(reason)
    )

    result
  end

  defp log_if_last(result, _job), do: result
end
