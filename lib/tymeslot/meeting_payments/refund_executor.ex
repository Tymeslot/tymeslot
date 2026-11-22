defmodule Tymeslot.MeetingPayments.RefundExecutor do
  @moduledoc """
  Makes one attempt at a recorded refund (`RefundSchema`), outside any
  transaction, so a slow Stripe call never holds the payment's row lock.

  An attempt:

    1. Reloads the refund; a settled one returns its outcome and asks
       nothing of Stripe.
    2. Backfills a missing charge id (`ChargeBackfill`). While none can be
       found the refund stays pending; on the job's last attempt it fails
       with `"missing_charge"`.
    3. Claims the attempt (`RefundQueries.claim_attempt/1`): its number is
       committed and a lease taken before Stripe is called, so two
       executors never call Stripe for one refund at once, and an attempt
       whose process dies has still spent its idempotency key. Releasing
       the lease and failing the refund apply only while this claim is the
       latest, so an attempt that outlived its lease decides nothing but a
       refund Stripe made.
    4. From the second attempt on, lists the charge's refunds first and
       adopts the one carrying this refund's id in its metadata: an earlier
       attempt may have been made at Stripe without its answer arriving. A
       list that fails sends nothing. The job's last attempt only lists:
       with no attempt after it to find out how a new request ended, it
       never sends one, and fails the refund with `"retries_exhausted"`
       only once the list shows Stripe never made it.
    5. Asks Stripe for the refund under the attempt's own key
       (`IdempotencyKey.for_intent(:refund, id, attempt)`), so a later
       attempt never replays an error Stripe stored against an earlier key.
       The first attempt of a refund carrying a `legacy_idempotency_key`
       replays that key with the request first sent under it, which carried
       no refund id; adoption then knows such a refund by its payment and
       amount.
    6. Settles by the outcome (`RefundOutcome`): a refund Stripe accepted
       is added to the payment's refunded total in one short transaction
       under the payment's lock, which also enqueues the attendee's email;
       one to retry releases the lease; a refusal settles the refund
       `failed` and sends `Refunds.FailureNotice`.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Stripe.IdempotencyKey
  alias Tymeslot.Integrations.Stripe.Refunds, as: StripeRefunds
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.ChargeBackfill
  alias Tymeslot.MeetingPayments.RefundedTotal
  alias Tymeslot.MeetingPayments.RefundOutcome
  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.Refunds.FailureNotice
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.MeetingPayments.Telemetry
  alias Tymeslot.MeetingPayments.Workers.ExecuteRefund
  alias Tymeslot.Repo
  alias Tymeslot.Workers.SendBookingPaymentRefunded

  # One page; a booking payment sees nowhere near this many refunds.
  @list_limit 100

  @type result ::
          {:ok, RefundSchema.t()}
          | {:pending, RefundSchema.t()}
          | {:error, :not_found | :missing_charge | :refund_failed}

  @doc """
  Makes one attempt at `refund`; see the moduledoc. Raises `ArgumentError`
  inside a transaction.

  Options:

    * `:deadline_ms` (default 10 000): how long the Stripe call may take.
    * `:from_job` (default `false`): called by `ExecuteRefund`, whose own
      backoff schedules the next attempt. Otherwise a refund left pending
      has its job rescheduled to run at once.
    * `:last_attempt` (default `false`): no attempt follows, so the attempt
      only looks for the refund at Stripe (step 4), and a refund whose
      charge cannot be found fails.
  """
  @spec run(RefundSchema.t(), keyword()) :: result()
  def run(%RefundSchema{id: id}, opts) do
    if RefundQueries.in_transaction?(),
      do: raise(ArgumentError, "a refund is executed outside any transaction")

    opts = Keyword.validate!(opts, deadline_ms: 10_000, from_job: false, last_attempt: false)

    case RefundQueries.get(id) do
      %RefundSchema{status: :pending} = refund ->
        payment = BookingPaymentQueries.get(refund.booking_payment_id)
        with_charge(refund, payment, opts)

      settled_or_nil ->
        settled(settled_or_nil)
    end
  end

  @doc """
  Records a refund of `amount_cents` Stripe made of the `locked` payment, as
  `stripe_refund`: the refunded total and the status that follows from it.
  Call it in the transaction holding the payment's row lock.
  """
  @spec record_refunded(BookingPaymentSchema.t(), pos_integer(), map()) ::
          {:ok, BookingPaymentSchema.t()} | {:error, Ecto.Changeset.t()}
  def record_refunded(locked, amount_cents, stripe_refund) do
    new_total = refunded_total(locked, amount_cents, stripe_refund)

    new_status =
      cond do
        new_total >= locked.amount_cents -> :refunded
        new_total > 0 -> :partially_refunded
        true -> locked.status
      end

    with {:ok, updated} <-
           BookingPaymentQueries.update(locked, %{
             refunded_amount_cents: new_total,
             status: new_status
           }) do
      Telemetry.emit_status_changed(locked.status, updated.status, :host_refund)
      {:ok, updated}
    end
  end

  @doc """
  The params of a refund of `amount_cents` of `payment` at Stripe, with the
  charge expanded so the answer carries Stripe's refunded total.
  """
  @spec stripe_params(BookingPaymentSchema.t(), pos_integer(), String.t() | nil) :: map()
  def stripe_params(payment, amount_cents, reason) do
    %{
      charge: payment.stripe_charge_id,
      amount: amount_cents,
      metadata: metadata(payment),
      expand: ["charge"]
    }
    |> put_reason(reason)
    |> put_refund_application_fee(payment)
  end

  @doc """
  Enqueues the attendee's refund email for `payment`. A failed insert is
  logged and does not undo the refund.
  """
  @spec enqueue_refund_email(BookingPaymentSchema.t()) :: :ok
  def enqueue_refund_email(payment) do
    case %{booking_payment_id: payment.id} |> SendBookingPaymentRefunded.new() |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue refund email",
          booking_payment_id: payment.id,
          reason: LogFormat.reason(reason)
        )

        :ok
    end
  end

  defp settled(nil), do: {:error, :not_found}
  defp settled(%RefundSchema{status: :succeeded} = refund), do: {:ok, refund}
  defp settled(%RefundSchema{status: :failed}), do: {:error, :refund_failed}
  defp settled(%RefundSchema{status: :pending} = refund), do: {:pending, refund}

  defp with_charge(refund, %{stripe_charge_id: charge} = payment, opts)
       when is_binary(charge) and charge != "",
       do: attempt(refund, payment, opts)

  defp with_charge(refund, payment, opts) do
    case ChargeBackfill.backfill(payment, payment.stripe_payment_intent_id) do
      {:ok, payment} ->
        attempt(refund, payment, opts)

      {:error, reason} ->
        Logger.warning("Refund waits for its payment's charge id",
          refund_id: refund.id,
          booking_payment_id: payment.id,
          reason: LogFormat.reason(reason)
        )

        if opts[:last_attempt] do
          with {:error, :refund_failed} <- claim_and_fail(refund, "missing_charge"),
               do: {:error, :missing_charge}
        else
          retry_later(refund, opts)
        end
    end
  end

  defp claim_and_fail(refund, code) do
    case RefundQueries.claim_attempt(refund) do
      {:ok, claimed} -> fail(claimed, code)
      :busy -> {:pending, refund}
      :not_pending -> refund.id |> RefundQueries.get() |> settled()
    end
  end

  defp attempt(refund, payment, opts) do
    case RefundQueries.claim_attempt(refund) do
      {:ok, claimed} ->
        claimed |> outcome(payment, opts) |> conclude(claimed, payment, opts)

      :busy ->
        {:pending, refund}

      :not_pending ->
        refund.id |> RefundQueries.get() |> settled()
    end
  end

  defp outcome(refund, payment, opts) do
    cond do
      opts[:last_attempt] -> adopt(refund, payment, fn -> {:failed, "retries_exhausted"} end)
      refund.attempt == 1 -> created(refund, payment, opts)
      true -> adopt(refund, payment, fn -> created(refund, payment, opts) end)
    end
  end

  defp adopt(refund, payment, when_not_made) do
    case made_earlier(refund, payment) do
      {:ok, nil} -> when_not_made.()
      {:ok, made} -> RefundOutcome.classify({:ok, made})
      {:error, reason} -> {:retry, reason}
    end
  end

  defp created(refund, payment, opts),
    do: refund |> create(payment, opts) |> RefundOutcome.classify()

  # The charge is expanded so an adopted refund carries Stripe's refunded
  # total as a created one does.
  defp made_earlier(refund, payment) do
    params = %{charge: payment.stripe_charge_id, limit: @list_limit, expand: ["data.charge"]}

    with {:ok, %{"data" => refunds} = page} <-
           StripeRefunds.list(params, connect_account: payment.stripe_account_id) do
      if page["has_more"] do
        Logger.warning("Charge has more refunds than one page lists",
          refund_id: refund.id,
          booking_payment_id: payment.id
        )
      end

      {:ok, Enum.find(refunds, &made_for?(&1, refund, payment))}
    end
  end

  # A refund carries the id of the row it was made for, except one sent
  # under a legacy key, which is known by its payment and amount instead.
  defp made_for?(%{"metadata" => %{"tymeslot_refund_id" => id}}, refund, _payment),
    do: id == refund.id

  defp made_for?(%{"metadata" => %{"booking_payment_id" => payment_id}} = made, refund, payment)
       when is_binary(refund.legacy_idempotency_key),
       do: payment_id == payment.id and made["amount"] == refund.amount_cents

  defp made_for?(_made, _refund, _payment), do: false

  defp create(refund, payment, opts) do
    {params, key} = request(refund, payment)

    StripeRefunds.create(params,
      connect_account: payment.stripe_account_id,
      idempotency_key: key,
      deadline_ms: opts[:deadline_ms]
    )
  end

  # Stripe refuses a key reused with different params, so a legacy key is
  # sent with the request first made under it, which named no refund row.
  defp request(%RefundSchema{attempt: 1, legacy_idempotency_key: key} = refund, payment)
       when is_binary(key),
       do: {stripe_params(payment, refund.amount_cents, refund.reason), key}

  defp request(%RefundSchema{id: id, attempt: attempt} = refund, payment) do
    params =
      payment
      |> stripe_params(refund.amount_cents, refund.reason)
      |> put_in([:metadata, :tymeslot_refund_id], id)

    {params, IdempotencyKey.for_intent(:refund, id, attempt)}
  end

  # A series payment names its series instead of a meeting.
  defp metadata(%{series_id: series_id} = payment) when is_binary(series_id),
    do: %{series_id: series_id, booking_payment_id: payment.id}

  defp metadata(payment), do: %{meeting_id: payment.meeting_id, booking_payment_id: payment.id}

  # Stripe rejects a blank `reason` ("cannot be unset"), so it is sent only
  # when there is one.
  defp put_reason(params, reason) when is_binary(reason) and reason != "",
    do: Map.put(params, :reason, reason)

  defp put_reason(params, _reason), do: params

  # Stripe errors if asked to refund an application fee never collected.
  defp put_refund_application_fee(params, %{application_fee_cents: fee})
       when is_integer(fee) and fee > 0,
       do: Map.put(params, :refund_application_fee, true)

  defp put_refund_application_fee(params, _payment), do: params

  defp conclude({:succeeded, stripe_refund}, refund, payment, opts),
    do: record_success(refund, payment, stripe_refund, opts)

  defp conclude({:retry, reason}, refund, _payment, opts) do
    Logger.warning("Refund attempt failed, to be retried",
      refund_id: refund.id,
      attempt: refund.attempt,
      reason: LogFormat.reason(reason)
    )

    RefundQueries.release(refund)
    retry_later(refund, opts)
  end

  defp conclude({:failed, code}, refund, _payment, _opts), do: fail(refund, code)

  defp record_success(refund, payment, stripe_refund, opts) do
    attrs = %{status: :succeeded, stripe_refund_id: stripe_refund["id"], settled_at: now()}

    recorded =
      Repo.transaction(fn ->
        with {:ok, locked} <- BookingPaymentQueries.get_for_update(payment.id),
             {:ok, settled} <- RefundQueries.settle(refund, attrs),
             {:ok, _updated} <- record_refunded(locked, refund.amount_cents, stripe_refund) do
          enqueue_refund_email(locked)
          settled
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case recorded do
      {:ok, settled} ->
        {:ok, settled}

      {:error, :not_pending} ->
        refund.id |> RefundQueries.get() |> settled()

      # Stripe made the refund; the next attempt adopts it and records it.
      {:error, reason} ->
        Logger.error("Refund made at Stripe could not be recorded",
          refund_id: refund.id,
          stripe_refund_id: stripe_refund["id"],
          reason: LogFormat.reason(reason)
        )

        RefundQueries.release(refund)
        retry_later(refund, opts)
    end
  end

  defp fail(claimed, code) do
    attrs = %{status: :failed, failure_code: code, settled_at: now()}

    case RefundQueries.settle_claimed(claimed, attrs) do
      {:ok, failed} ->
        FailureNotice.deliver(failed, code)
        {:error, :refund_failed}

      {:error, :not_pending} ->
        claimed.id |> RefundQueries.get() |> settled()
    end
  end

  defp retry_later(refund, opts) do
    unless opts[:from_job], do: ExecuteRefund.reschedule(refund.id, in: 0)
    {:pending, refund}
  end

  # Stripe's refunded total for the charge, which counts this refund once
  # however often it is answered, and never below the recorded refunds. A
  # refund without the expanded charge is added to the recorded refunds.
  defp refunded_total(payment, _amount_cents, %{"charge" => %{"amount_refunded" => total}})
       when is_integer(total),
       do: RefundedTotal.with_stripe_refunded(payment, total)

  defp refunded_total(payment, amount_cents, _stripe_refund),
    do: RefundedTotal.with_refund_added(payment, amount_cents)

  defp now, do: DateTime.utc_now(:second)
end
