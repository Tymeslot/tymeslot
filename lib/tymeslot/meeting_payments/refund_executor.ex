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
       whose process dies leaves its idempotency key in use for the next.
       Releasing the lease and failing the refund apply only while this
       claim is the latest, so an attempt that outlived its lease decides
       nothing but a refund Stripe made.
    4. From the second attempt on, lists the charge's refunds first and
       adopts the one carrying this refund's id in its metadata: an earlier
       attempt may have been made at Stripe without its answer arriving. A
       list that fails sends nothing. The job's last attempt only lists:
       with no attempt after it to find out how a new request ended, it
       never sends one, and fails the refund with `"retries_exhausted"`
       only once the list shows Stripe never made it.
    5. Asks Stripe for the refund under the key in use
       (`IdempotencyKey.for_intent(:refund, id, key_attempt)`; see
       `RefundSchema`). An attempt following one Stripe stored no answer
       for (a timeout, a request still in flight) sends that attempt's key
       again, so Stripe returns the refund the earlier request made rather
       than making a second; the listing in step 4 alone cannot promise
       that, as Stripe may not list a refund it is still making. Once
       Stripe has stored an answer under a key that leaves the refund open
       (`RefundOutcome`'s `:retry_new_key`), the next attempt takes its
       own key, so it never replays that answer, and runs no sooner than
       `settle_wait_seconds/1` allows, giving Stripe time to list a refund
       the answered request may have made.
       A refund carrying a `legacy_idempotency_key` replays that key, with
       the request first sent under it (which named no refund row), on
       every attempt until 24 hours after `legacy_since`, while Stripe may
       keep it: steps 4 and the last attempt's rule do not apply then. From
       then on it is attempted as any other, from its first attempt on, and
       step 4 also adopts a refund of its payment and amount made since
       `legacy_since` and recorded on no row.
    6. Settles by the outcome (`RefundOutcome`): a refund Stripe accepted
       is recorded by `Refunds.Settlement.settle_succeeded/2`, as the
       webhooks record one, so whichever learns of it first sends the
       attendee's one email; one to retry releases the lease; a refusal
       settles the refund `failed` and sends `Refunds.FailureNotice`.
  """

  require Logger

  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Stripe.IdempotencyKey
  alias Tymeslot.Integrations.Stripe.Refunds, as: StripeRefunds
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.ChargeBackfill
  alias Tymeslot.MeetingPayments.RefundOutcome
  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.Refunds.FailureNotice
  alias Tymeslot.MeetingPayments.Refunds.Settlement
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.MeetingPayments.Workers.ExecuteRefund

  # One page; a booking payment sees nowhere near this many refunds.
  @list_limit 100

  # How long Stripe keeps an idempotency key, and the margin given for the
  # gap between Stripe's clock and ours, taken in the safe direction: the
  # key is trusted a little less long, and a refund counts as made since
  # `legacy_since` a little earlier.
  @legacy_key_kept_seconds 24 * 60 * 60
  @clock_margin_seconds 5 * 60

  # How long Stripe is given to list a refund that a request it answered
  # with an error (a 5xx, say) may still have made, before the next attempt
  # reads the list and, finding nothing, sends under a new key. Stripe
  # promises no bound on that lag, and 5xx answers come in incidents, when
  # it is at its longest. Too short a wait costs a second refund of money
  # the host may no longer hold; a long one costs only a refund made a few
  # minutes later after a rare error. Ten minutes also gives the
  # `charge.refunded` webhook time to record a refund the request made.
  @settle_seconds 10 * 60

  @type result ::
          {:ok, RefundSchema.t()}
          | {:pending, RefundSchema.t()}
          | {:stuck, RefundSchema.t()}
          | {:error, :not_found | :missing_charge | :refund_failed}

  @doc """
  How many seconds `refund` must wait before its next attempt. An attempt
  whose request Stripe answered in a way that leaves the refund open gave
  up its key (`RefundOutcome`'s `:retry_new_key`, leaving `key_attempt`
  unset), and the next one, which sends under a new key, waits until
  #{@settle_seconds} seconds after that attempt began (its claim sets
  `updated_at`). Otherwise 0.
  """
  @spec settle_wait_seconds(RefundSchema.t()) :: non_neg_integer()
  def settle_wait_seconds(%RefundSchema{
        status: :pending,
        attempt: attempt,
        key_attempt: nil,
        updated_at: %DateTime{} = attempted_at
      })
      when attempt > 0,
      do: max(@settle_seconds - DateTime.diff(Clock.utc_now(), attempted_at, :second), 0)

  def settle_wait_seconds(%RefundSchema{}), do: 0

  @doc """
  Makes one attempt at `refund`; see the moduledoc. Raises `ArgumentError`
  inside a transaction.

  Options:

    * `:deadline_ms` (default 10 000): how long the Stripe call may take.
    * `:from_job` (default `false`): called by `ExecuteRefund`, whose own
      backoff schedules the next attempt. Otherwise a refund left pending
      has its job rescheduled to run at once, or in #{@settle_seconds}
      seconds when the next attempt is to send under a new key.
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

  # The params of a refund of `amount_cents` of `payment` at Stripe, with the
  # charge expanded so the answer carries Stripe's refunded total.
  @spec stripe_params(BookingPaymentSchema.t(), pos_integer(), String.t() | nil) :: map()
  defp stripe_params(payment, amount_cents, reason) do
    %{
      charge: payment.stripe_charge_id,
      amount: amount_cents,
      metadata: metadata(payment),
      expand: ["charge"]
    }
    |> put_reason(reason)
    |> put_refund_application_fee(payment)
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

  # A legacy key is replayed for as long as Stripe may keep it, the last
  # attempt included: the replay can only return the one refund made under
  # that key, or make it if none was, so it never adds a refund a later
  # attempt could not account for, and Stripe's answer is authoritative.
  # Once the key may be gone, the row is attempted as any other, looking
  # first for a refund the key made.
  defp outcome(refund, payment, opts) do
    cond do
      legacy_key_kept?(refund) ->
        refund |> create(payment, opts) |> RefundOutcome.classify()

      opts[:last_attempt] ->
        adopt(refund, payment, fn -> {:failed, "retries_exhausted"} end)

      refund.attempt == 1 and is_nil(refund.legacy_idempotency_key) ->
        created(refund, payment, opts)

      true ->
        adopt(refund, payment, fn -> created(refund, payment, opts) end)
    end
  end

  defp legacy_key_kept?(%RefundSchema{legacy_since: %DateTime{} = since}),
    do:
      DateTime.diff(DateTime.utc_now(), since, :second) <
        @legacy_key_kept_seconds - @clock_margin_seconds

  defp legacy_key_kept?(_refund), do: false

  defp adopt(refund, payment, when_not_made) do
    case made_earlier(refund, payment) do
      {:ok, nil} -> when_not_made.()
      {:ok, made} -> RefundOutcome.classify({:ok, made})
      {:error, reason} -> RefundOutcome.classify_list_error(reason)
    end
  end

  defp created(refund, payment, opts) do
    refund
    |> create(payment, opts)
    |> RefundOutcome.classify(later_attempt: refund.attempt > 1)
  end

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
  # under a legacy key, which is known by its payment and amount instead:
  # one made no earlier than the key could have been sent, and recorded on
  # no row yet, since a payment can have many refunds of one amount (a
  # series refunded session by session).
  defp made_for?(%{"metadata" => %{"tymeslot_refund_id" => id}}, refund, _payment),
    do: id == refund.id

  defp made_for?(%{"metadata" => %{"booking_payment_id" => payment_id}} = made, refund, payment)
       when is_binary(refund.legacy_idempotency_key) do
    payment_id == payment.id and made["amount"] == refund.amount_cents and
      is_integer(made["created"]) and
      made["created"] >= DateTime.to_unix(refund.legacy_since) - @clock_margin_seconds and
      is_nil(RefundQueries.by_stripe_refund_id(made["id"]))
  end

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
  defp request(%RefundSchema{legacy_idempotency_key: key} = refund, payment)
       when is_binary(key) do
    if legacy_key_kept?(refund),
      do: {stripe_params(payment, refund.amount_cents, refund.reason), key},
      else: attempt_request(refund, payment)
  end

  defp request(refund, payment), do: attempt_request(refund, payment)

  # The key in use is set by the claim this attempt holds.
  defp attempt_request(%RefundSchema{id: id, key_attempt: key_attempt} = refund, payment)
       when is_integer(key_attempt) do
    params =
      payment
      |> stripe_params(refund.amount_cents, refund.reason)
      |> put_in([:metadata, :tymeslot_refund_id], id)

    {params, IdempotencyKey.for_intent(:refund, id, key_attempt)}
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

  defp conclude({:succeeded, stripe_refund}, refund, _payment, opts),
    do: record_success(refund, stripe_refund, opts)

  defp conclude({:retry, reason}, refund, _payment, opts) do
    Logger.warning("Refund attempt failed, to be retried",
      refund_id: refund.id,
      attempt: refund.attempt,
      reason: LogFormat.reason(reason)
    )

    RefundQueries.release(refund)
    retry_later(refund, opts)
  end

  defp conclude({:retry_new_key, reason}, refund, _payment, opts) do
    Logger.warning("Refund attempt failed, to be retried under a new key",
      refund_id: refund.id,
      attempt: refund.attempt,
      reason: LogFormat.reason(reason)
    )

    RefundQueries.release(refund, new_key: true)
    retry_later(refund, opts, @settle_seconds)
  end

  defp conclude({:failed, code}, refund, _payment, _opts), do: fail(refund, code)

  defp conclude({:failed, code, stripe_refund_id}, refund, _payment, _opts),
    do: fail(refund, code, stripe_refund_id)

  defp conclude({:unlistable, reason}, refund, _payment, _opts) do
    Logger.warning("Refund attempt cannot read the charge's refunds, left pending",
      refund_id: refund.id,
      reason: LogFormat.reason(reason)
    )

    RefundQueries.release(refund)
    FailureNotice.stuck(refund)
    {:stuck, refund}
  end

  defp record_success(refund, stripe_refund, opts) do
    case Settlement.settle_succeeded(refund, stripe_refund) do
      # Already settled, possibly failed: Stripe's later verdict stands
      # over this attempt's answer.
      {:ok, settled, _settled_or_already} ->
        settled(settled)

      {:error, :not_found} ->
        {:error, :not_found}

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

  # A refund Stripe ended records its Stripe refund, which marks the
  # failure as Stripe's verdict on it (`RefundSchema.ended_at_stripe_codes/0`).
  # One another row already holds is failed without it.
  defp fail(claimed, code, stripe_refund_id \\ nil) do
    attrs = %{
      status: :failed,
      failure_code: code,
      stripe_refund_id: stripe_refund_id,
      settled_at: now()
    }

    case RefundQueries.settle_claimed(claimed, attrs) do
      {:ok, failed} ->
        FailureNotice.deliver(failed, code)
        {:error, :refund_failed}

      {:error, :stripe_refund_taken} ->
        fail(claimed, code)

      {:error, :not_pending} ->
        claimed.id |> RefundQueries.get() |> settled()
    end
  end

  defp retry_later(refund, opts, seconds \\ 0) do
    unless opts[:from_job], do: ExecuteRefund.reschedule(refund.id, in: seconds)
    {:pending, refund}
  end

  defp now, do: DateTime.utc_now(:second)
end
