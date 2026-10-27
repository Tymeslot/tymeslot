defmodule Tymeslot.MeetingPayments.Workers.RefundLatePayment do
  @moduledoc """
  Refunds, in full, a payment that completed after its booking had expired
  and its slot had been given to someone else, or for a host whose account
  is pending deletion.

  `CheckoutSessionCompleted` records such a payment as paid, leaves the
  meeting expired and inserts this job in the same transaction, so the
  webhook no longer waits on Stripe and a lasting Stripe failure no longer
  rolls back every delivery while the money sits unseen. Until the refund
  goes through, the booking is on the host's outstanding-refunds list, where
  the host can also refund it by hand.

  The refund needs the payment's charge id. The webhook backfills it from
  Stripe before inserting this job, but commits the payment and the job
  whether or not that worked, so each attempt here first backfills a charge
  id still missing (`ChargeBackfill`), and an attempt that cannot is retried
  like any other failed one. The refusals below are checked before that,
  since they need no charge id and no Stripe call.

  The refund is `Refunds.issue_refund/3`, whose Stripe idempotency key is
  derived from the payment id, its refunded total and the amount
  (`refund:<id>:<total after>:<amount>`). Every attempt of this job asks for
  the same remaining balance from the same refunded total, so the key is the
  same each time: when Stripe accepted a refund but the transaction that
  records it rolled back, the retry gets the same refund back from Stripe
  instead of a second one. The attendee's refund email is enqueued in that
  same transaction, so only once Stripe has accepted the refund.

  Retries are spread over about four hours (`backoff/1`), well inside the
  24 hours Stripe keeps an idempotency key. When the last attempt fails an
  admin alert is raised, and the booking stays on the host's list.

  A refund that no retry can make is discarded at once, with one log line,
  rather than retried for four hours towards an alert:

    * `:under_dispute`: Stripe holds the money until the dispute is decided.
      A dispute the attendee wins in full returns it to them. One the host
      wins sets the payment back to `paid` (or `partially_refunded`), and
      one the attendee wins only in part leaves it `partially_refunded`;
      either way the rest is still owed, so the job is scheduled again
      (`new_after_dispute/1`) and refunds what is left, the booking on the
      host's outstanding-refunds list until it has run.
    * `:outside_refund_window` and `:not_paid`: the payment is `paid` and
      its booking expired, so it stays on the host's outstanding-refunds
      list, offered as a refund to make in Stripe.

  Inserted at most once per booking payment and reason: the uniqueness
  covers every state, completed and discarded included, so a redelivered
  completion (or dispute outcome) can never refund twice. The job a decided
  dispute schedules carries `reason: "after_dispute"`, so the first job,
  discarded while the dispute was open, does not swallow it.
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 10,
    unique: [keys: [:booking_payment_id, :reason], states: :all, period: :infinity]

  require Logger

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.ChargeBackfill
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.Workers.SendBookingPaymentRefunded

  # Sixty seconds, doubling, capped at an hour: nine waits between ten
  # attempts add up to 14_580 seconds (4h03m).
  @base_backoff_seconds 60
  @max_backoff_seconds 3_600

  # Refusals no retry can turn round; see the moduledoc for where each
  # leaves the money owed.
  @unretryable [:not_paid, :outside_refund_window, :under_dispute]

  @behaviour ExpectedJobOutcome

  # The booking is left with the host or with Stripe's dispute, as the
  # moduledoc describes, so the discard is not a failure to record.
  @impl ExpectedJobOutcome
  def expected_outcome?(reason), do: reason in @unretryable

  @doc """
  Builds the job for `booking_payment_id`. Insert it in the transaction that
  records the payment as paid.
  """
  @spec new_for(Ecto.UUID.t()) :: Oban.Job.changeset()
  def new_for(booking_payment_id), do: new(%{booking_payment_id: booking_payment_id})

  @doc """
  Builds the job for `booking_payment_id` once a decided dispute has left
  part or all of the payment with the host: a won dispute, or one lost only
  in part. Insert it in the transaction that records the outcome.
  """
  @spec new_after_dispute(Ecto.UUID.t()) :: Oban.Job.changeset()
  def new_after_dispute(booking_payment_id),
    do: new(%{booking_payment_id: booking_payment_id, reason: "after_dispute"})

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"booking_payment_id" => id}} = job) do
    case refund(id) do
      {:ok, _refunded} ->
        :ok

      {:error, :already_refunded} ->
        notify_attendee_once(id)

      {:error, :not_found} ->
        {:discard, "booking_payment not found"}

      {:error, reason} when reason in @unretryable ->
        Logger.warning("Late payment refund cannot be made automatically, left to the host",
          booking_payment_id: id,
          reason: reason
        )

        {:discard, reason}

      {:error, reason} ->
        if job.attempt >= job.max_attempts, do: alert(job, id, reason)
        {:error, reason}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}),
    do: min(@base_backoff_seconds * 2 ** (attempt - 1), @max_backoff_seconds)

  # A raise (a dropped connection, say) is an attempt failing like any other,
  # so it is returned rather than raised, and the last one is alerted on.
  defp refund(id) do
    with %BookingPaymentSchema{} = payment <- MeetingPayments.get_payment(id),
         :ok <- Refunds.refusal(payment),
         {:ok, payment} <- ensure_charge(payment) do
      Refunds.issue_refund(payment, Refunds.refundable_remaining_cents(payment))
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  rescue
    exception -> {:error, exception}
  end

  defp ensure_charge(%{stripe_charge_id: charge} = payment)
       when is_binary(charge) and charge != "",
       do: {:ok, payment}

  defp ensure_charge(payment),
    do: ChargeBackfill.backfill(payment, payment.stripe_payment_intent_id)

  # The payment is refunded already, by the host from the dashboard, or by
  # an earlier attempt whose refund Stripe accepted and `charge.refunded`
  # recorded after that attempt's own transaction rolled back. The host's
  # refund and a committed attempt each enqueued the email; the rolled-back
  # attempt did not. Unique over every state, the insert sends it only in
  # that last case.
  defp notify_attendee_once(id) do
    email =
      SendBookingPaymentRefunded.new(%{booking_payment_id: id},
        unique: [keys: [:booking_payment_id], states: :all, period: :infinity]
      )

    case Oban.insert(email) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp alert(job, id, reason) do
    Logger.error("Late payment refund failed for good",
      booking_payment_id: id,
      reason: LogFormat.reason(reason)
    )

    AdminAlerts.report(:late_payment_refund_failed,
      summary: "A payment that completed after its slot was taken could not be refunded",
      reason: reason,
      context: %{booking_payment_id: id, oban_job_id: job.id}
    )
  end
end
