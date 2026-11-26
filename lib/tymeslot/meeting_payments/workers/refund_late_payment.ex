defmodule Tymeslot.MeetingPayments.Workers.RefundLatePayment do
  @moduledoc """
  Runs jobs queued before the release that brought in the refund outbox
  (`booking_payment_refunds`); delete in the release after it.

  Such a job refunds, in full, a payment that completed after its booking
  had expired and its slot had been given to someone else, or for a host
  whose account is pending deletion (`reason: "late"`), or what a decided
  dispute left with the host (`reason: "after_dispute"`). Nothing inserts
  such jobs: the webhooks record those refunds themselves
  (`Refunds.request_remaining_refund/2`).

  A run records the refund of the remaining balance
  (`Refunds.request_refund/4`, source `:late_payment`) and leaves it to
  `ExecuteRefund`, which makes it, retries it and reports a failure. An
  earlier attempt of the job may have refunded at Stripe under its key
  (`late_payment_refund:<id>:<reason>:<amount>`) without recording it, so
  the refund carries that key and the job's `inserted_at`, from when the
  key could first have been sent: the executor replays the key while Stripe
  keeps it, and adopts a refund it made after that.

  The refusals no retry can turn round (`:not_paid`,
  `:outside_refund_window`, `:under_dispute`) discard the job and leave the
  booking on the host's outstanding refunds, as does an amount the balance
  no longer holds. A payment refunded already (by the host, or by an
  earlier attempt whose refund `charge.refunded` recorded after that
  attempt's own transaction rolled back) has the attendee emailed once.
  The refund is recorded under a delivery claim, so a rerun records none.

  Any other failure (another refund of the payment still pending, a raise)
  is retried over about four hours; when the last attempt fails too, a
  `:late_payment_refund_failed` admin alert is raised, as nobody else
  learns that the attendee is still owed the money.
  """

  use Oban.Worker,
    queue: :payments,
    max_attempts: 10,
    unique: [keys: [:booking_payment_id, :reason], states: :all, period: :infinity]

  require Logger

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Infrastructure.Logging.LogFormat

  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.Repo
  alias Tymeslot.Workers.Backoff
  alias Tymeslot.Workers.DeliveryClaims
  alias Tymeslot.Workers.SendBookingPaymentRefunded

  @claim "late_payment_refund_requested"

  @base_backoff_seconds 60
  @max_backoff_seconds 3_600

  # Refusals no retry can turn round: the booking stays with the host.
  @unretryable [:not_paid, :outside_refund_window, :under_dispute, :invalid_amount]

  @behaviour ExpectedJobOutcome

  @impl ExpectedJobOutcome
  def expected_outcome?(reason), do: reason in @unretryable

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"booking_payment_id" => id} = args} = job) do
    case BookingPayments.get_payment(id) do
      %BookingPaymentSchema{} = payment -> payment |> request(job, args) |> result(job, id)
      nil -> {:discard, :not_found}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}),
    do: Backoff.exponential(attempt, @base_backoff_seconds, @max_backoff_seconds)

  # A raise (a dropped connection, say) is an attempt failing like any
  # other, so the last one is still alerted on.
  defp request(payment, job, args) do
    if DeliveryClaims.claimed?(job.id, @claim),
      do: {:ok, :requested},
      else: request_once(payment, job, Map.get(args, "reason", "late"))
  rescue
    exception -> {:error, exception}
  end

  # The claim and the refund commit together; a refusal rolls both back.
  defp request_once(payment, job, reason) do
    amount = Refunds.refundable_remaining_cents(payment)

    Repo.transaction(fn ->
      with :claimed <- claim(job.id),
           {:ok, refund} <-
             Refunds.request_refund(payment, amount, :late_payment,
               legacy_idempotency_key: "late_payment_refund:#{payment.id}:#{reason}:#{amount}",
               legacy_since: job.inserted_at,
               enqueue_now: true
             ) do
        refund
      else
        :already_claimed -> :requested
        {:error, refusal} -> Repo.rollback(refusal)
      end
    end)
  end

  # A job with no id (built by hand) cannot run twice.
  defp claim(nil), do: :claimed
  defp claim(job_id), do: DeliveryClaims.claim(job_id, @claim)

  defp result({:ok, _requested}, _job, _id), do: :ok
  defp result({:error, :already_refunded}, _job, id), do: notify_attendee_once(id)
  defp result({:error, :not_found}, _job, _id), do: {:discard, :not_found}

  defp result({:error, reason}, _job, id) when reason in @unretryable do
    Logger.warning("Late payment refund cannot be made automatically, left to the host",
      booking_payment_id: id,
      reason: reason
    )

    {:discard, reason}
  end

  defp result({:error, reason}, job, id) do
    if job.attempt >= job.max_attempts, do: alert(job, id, reason)
    {:error, reason}
  end

  # Unique over every state, the insert sends the email only if nothing
  # sent it for this payment before.
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
