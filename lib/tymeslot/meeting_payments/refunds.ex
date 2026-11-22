defmodule Tymeslot.MeetingPayments.Refunds do
  @moduledoc """
  Issues refunds against `booking_payments` rows via the Stripe Refund
  API and reconciles the local row.

  `request_refund/4` records a refund (`RefundSchema`) under the payment's
  row lock, with no Stripe call, and with it a job that makes it
  (`Workers.ExecuteRefund`). `execute/2` makes one attempt outside any
  transaction (`RefundExecutor`), and `refund_now/4` does both, for a caller
  that waits on the answer. A pending refund counts against the refundable
  balance until it settles.

  The contract shared by `issue_refund/4` (system refunds, unscoped) and
  `issue_host_refund/5` (a host refunding a payment they took):

    * Refuses a payment `refusal/1` rules out, before any Stripe call:
      one never paid (`:not_paid`), one past the 60-day refund window
      (`:outside_refund_window`), and one Stripe holds for a dispute
      (`:under_dispute`).
    * Validates the requested amount is positive and does not exceed
      the remaining refundable balance.
    * Calls Stripe under the caller's idempotency key, which names the
      decision to refund rather than the payment's state, so every retry
      of one refund gets the same refund back from Stripe. A key built
      from the refunded total would change once the `charge.refunded`
      webhook recorded a refund whose own transaction rolled back, and
      the retry would refund again. Stripe requires the same parameters
      under a reused key, so the key must change with the amount, and a
      caller's retries must end inside the 24 hours Stripe keeps it.
    * Conditionally passes `refund_application_fee: true` only when
      the original charge had a non-zero application fee. Stripe
      errors if asked to refund a fee that was never collected.
    * Updates the local `booking_payments` row, transitioning status
      to `partially_refunded` or `refunded` based on the new total. The
      new total is Stripe's own refunded total for the charge, read from
      the refund's expanded charge and never lowering the recorded
      refunds (the `charge.refunded` webhook's rule), so a refund Stripe
      answers again for a replayed key is not counted twice. What a lost
      dispute took is added to it, never compared with it
      (`RefundedTotal`).
    * Synchronously enqueues an attendee refund email via
      `Tymeslot.Workers.SendBookingPaymentRefunded`.
  """

  alias Tymeslot.Integrations.Stripe
  alias Tymeslot.Integrations.Stripe.Refunds, as: StripeRefunds
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.Money
  alias Tymeslot.MeetingPayments.RefundedTotal
  alias Tymeslot.MeetingPayments.RefundExecutor
  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.MeetingPayments.Workers.ExecuteRefund
  alias Tymeslot.Repo

  @refund_window_days 60

  # The refund call runs while its transaction holds the payment's row lock,
  # so each attempt is bounded at 3 s to connect and 5 s to receive. The
  # request's 10 s deadline lets the client retry only a failure that left
  # time for another attempt as long (a refused connection, a 429,
  # `Stripe-Should-Retry: true`), never a timed-out receive, and caps each
  # receive at the time left. The call takes about 10 s at worst, plus one
  # connect timeout, inside the 15 s transaction timeout. The wait for a
  # pooled connection is capped at the time left separately from the
  # receive, so that bound assumes the pool is not contended.
  @stripe_connect_timeout_ms 3_000
  @stripe_receive_timeout_ms 5_000
  @stripe_deadline_ms 10_000

  # A requested refund's safety job runs this long after the request, by
  # when a caller making the refund itself has normally settled it.
  @safety_delay_seconds 120

  @requestable_sources RefundSchema.requestable_sources()

  @type refund_source :: :host | :cancellation | :approval_release | :late_payment | :series_host
  @type refusal ::
          :not_found
          | :not_paid
          | :outside_refund_window
          | :under_dispute
          | :already_refunded
          | :invalid_amount
          | :missing_charge
          | :refund_in_progress

  @type refund_error ::
          :not_paid
          | :outside_refund_window
          | :already_refunded
          | :under_dispute
          | :invalid_amount
          | :missing_charge
          | term()

  @doc """
  Returns the remaining refundable balance in cents for a booking payment:
  what is neither refunded nor in a pending refund
  (`RefundedTotal.refundable_cents/2`). The pending refunds are the
  payment's `pending_refund_cents`, as the host-facing queries fill it in;
  a payment loaded without it is looked up by its id, once.
  """
  @spec refundable_remaining_cents(BookingPaymentSchema.t()) :: non_neg_integer()
  def refundable_remaining_cents(%{pending_refund_cents: pending} = payment)
      when is_integer(pending),
      do: RefundedTotal.refundable_cents(payment, pending)

  def refundable_remaining_cents(%{id: id} = payment) when is_binary(id),
    do: RefundedTotal.refundable_cents(payment, RefundQueries.pending_cents(id))

  def refundable_remaining_cents(payment), do: RefundedTotal.refundable_cents(payment, 0)

  @doc """
  Records a refund of `amount_cents` of `payment`, decided by `source`, and
  the job that makes it. Asks nothing of Stripe; `execute/2` or the job does.

  One transaction, joining the caller's when there is one: the payment is
  locked, then `refusal/1` applies, a refunded payment is
  `:already_refunded`, and the amount must be a positive integer within the
  refundable balance (`refundable_remaining_cents/1`). An amount over it is
  `:refund_in_progress` while other refunds are pending, else
  `:invalid_amount`. A missing charge id is no refusal here: the attempt
  backfills it.

  Options:

    * `:host_user_id`: the host acting. Only a payment they took is found,
      decided under the lock; any other is `{:error, :not_found}`. Recorded
      as who asked.
    * `:reason`: the Stripe `reason` param.
    * `:legacy_idempotency_key`: the key the refund's first attempt is sent
      under, for a refund already sent under one elsewhere.
    * `:schedule_in` (default #{@safety_delay_seconds}): seconds until the
      job runs; `:enqueue_now` runs it at once, for a caller that does not
      make the refund itself.
  """
  @spec request_refund(BookingPaymentSchema.t(), pos_integer(), refund_source(), keyword()) ::
          {:ok, RefundSchema.t()} | {:error, refusal()}
  def request_refund(%BookingPaymentSchema{} = payment, amount_cents, source, opts)
      when source in @requestable_sources do
    opts =
      Keyword.validate!(opts, [
        :host_user_id,
        :reason,
        :legacy_idempotency_key,
        :schedule_in,
        enqueue_now: false
      ])

    Repo.transaction(fn ->
      with {:ok, locked} <- lock(payment.id, opts[:host_user_id]),
           :ok <- refusal(locked),
           :ok <- requestable(locked, amount_cents, RefundQueries.pending_cents(locked.id)),
           {:ok, refund} <- insert_request(locked, amount_cents, source, opts) do
        refund
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Makes one attempt at a recorded refund, outside any transaction; see
  `RefundExecutor.run/2` for the steps and options. Returns the refund once
  it succeeded, `{:pending, refund}` while it waits for another attempt,
  `{:error, :refund_failed}` once it failed, and `{:error, :missing_charge}`
  when the last attempt found no charge to refund.
  """
  @spec execute(RefundSchema.t(), keyword()) ::
          {:ok, RefundSchema.t()}
          | {:pending, RefundSchema.t()}
          | {:error, refusal() | :refund_failed}
  defdelegate execute(refund, opts), to: RefundExecutor, as: :run

  @doc """
  Records a refund (`request_refund/4`) and makes its first attempt at once
  (`execute/2`), for a caller waiting on the outcome.
  """
  @spec refund_now(BookingPaymentSchema.t(), pos_integer(), refund_source(), keyword()) ::
          {:ok, RefundSchema.t()}
          | {:pending, RefundSchema.t()}
          | {:error, refusal() | :refund_failed}
  def refund_now(payment, amount_cents, source, opts) do
    with {:ok, refund} <- request_refund(payment, amount_cents, source, opts),
         do: execute(refund, deadline_ms: @stripe_deadline_ms)
  end

  defp lock(id, nil), do: BookingPaymentQueries.get_for_update(id)
  defp lock(id, host_user_id), do: BookingPaymentQueries.get_for_update(id, host_user_id)

  defp requestable(%{status: :refunded}, _amount_cents, _pending), do: {:error, :already_refunded}

  defp requestable(payment, amount_cents, pending) do
    cond do
      not is_integer(amount_cents) or amount_cents <= 0 -> {:error, :invalid_amount}
      amount_cents <= RefundedTotal.refundable_cents(payment, pending) -> :ok
      pending > 0 -> {:error, :refund_in_progress}
      true -> {:error, :invalid_amount}
    end
  end

  defp insert_request(payment, amount_cents, source, opts) do
    changeset =
      RefundSchema.request_changeset(%RefundSchema{}, %{
        booking_payment_id: payment.id,
        amount_cents: amount_cents,
        source: source,
        reason: opts[:reason],
        requested_by_user_id: opts[:host_user_id],
        legacy_idempotency_key: opts[:legacy_idempotency_key]
      })

    schedule_in =
      if opts[:enqueue_now], do: 0, else: opts[:schedule_in] || @safety_delay_seconds

    with {:ok, refund} <- RefundQueries.insert(changeset),
         {:ok, _job} <-
           Oban.insert(ExecuteRefund.new(%{refund_id: refund.id}, schedule_in: schedule_in)) do
      {:ok, refund}
    end
  end

  @doc """
  What a host's cancellation of one booking refunds by default: the
  remaining balance, or, when the payment paid for a whole series, one
  session's price (`unit_price_cents` snapshotted on the series), capped at
  what remains. A series payment whose series is gone falls back to the
  remaining balance.
  """
  @spec default_cancellation_refund_cents(BookingPaymentSchema.t()) :: non_neg_integer()
  def default_cancellation_refund_cents(%BookingPaymentSchema{series_id: id} = payment)
      when is_binary(id) do
    remaining = refundable_remaining_cents(payment)

    case Repo.preload(payment, :series).series do
      %{unit_price_cents: unit} when is_integer(unit) and unit > 0 -> min(unit, remaining)
      _gone -> remaining
    end
  end

  def default_cancellation_refund_cents(payment), do: refundable_remaining_cents(payment)

  @doc """
  Returns `true` when the host still holds money the attendee has not been
  given back.

  Deliberately says nothing about the #{@refund_window_days}-day window: the
  attendee is out of pocket whether or not Tymeslot can still issue the refund
  itself, and a host past the window needs telling more urgently rather than
  less, since only their Stripe dashboard can settle it. Use `refundable?/1`
  to decide whether to offer the in-app refund.
  """
  @spec refund_outstanding?(BookingPaymentSchema.t() | nil) :: boolean()
  def refund_outstanding?(nil), do: false

  def refund_outstanding?(payment) do
    payment.status in BookingPaymentSchema.refundable_statuses() and
      refundable_remaining_cents(payment) > 0
  end

  @doc """
  Returns `true` when the payment still owes the attendee money and was paid
  within the #{@refund_window_days}-day refund window.

  Encapsulates both the outstanding-balance check and the time-window check so
  the constant has a single source of truth.
  """
  @spec refundable?(BookingPaymentSchema.t() | nil) :: boolean()
  def refundable?(payment),
    do: refund_outstanding?(payment) and within_refund_window?(payment)

  defp within_refund_window?(%{paid_at: %DateTime{} = paid_at}),
    do: DateTime.diff(DateTime.utc_now(), paid_at, :day) <= @refund_window_days

  defp within_refund_window?(_payment), do: false

  @doc """
  Returns why the payment cannot be refunded at all, from what is recorded
  locally: `:not_paid` without a paid time, `:outside_refund_window` past the
  #{@refund_window_days}-day window, `:under_dispute` while Stripe holds the
  money for a dispute.

  These are the refusals no retry turns round, and they need no Stripe call,
  so a caller about to make one (fetching a missing charge id, say) can check
  them first. `issue_refund/4` and `issue_host_refund/5` apply them too.
  """
  @spec refusal(BookingPaymentSchema.t()) ::
          :ok | {:error, :not_paid | :outside_refund_window | :under_dispute}
  def refusal(%{paid_at: nil}), do: {:error, :not_paid}

  # Stripe's Refund API rejects a disputed charge, so the dispute is caught
  # here rather than by a wasted round-trip that errors.
  def refusal(payment) do
    cond do
      not within_refund_window?(payment) -> {:error, :outside_refund_window}
      payment.status == :disputed -> {:error, :under_dispute}
      true -> :ok
    end
  end

  @doc """
  Parses raw refund-form params into a validated `{:ok, pos_integer()}` or
  a tagged `{:error, atom()}`.

  Accepts the standard `"refund_type"` param shape used by the payments UI:

    * `%{"refund_type" => "full"}` — issues the full remaining balance
    * `%{"refund_type" => "partial", "amount" => "15.00"}` — decimal string,
      commas normalised to periods

  Error atoms:
    * `:choose_type` — `refund_type` key is absent or unrecognised
    * `:invalid_amount` — amount string cannot be parsed or is not positive
    * `:exceeds_remaining` — parsed amount exceeds the remaining balance
  """
  @spec parse_refund_amount(BookingPaymentSchema.t(), map()) ::
          {:ok, pos_integer()} | {:error, :invalid_amount | :exceeds_remaining | :choose_type}
  def parse_refund_amount(payment, %{"refund_type" => "full"}) do
    {:ok, refundable_remaining_cents(payment)}
  end

  def parse_refund_amount(payment, %{"refund_type" => "partial", "amount" => raw}) do
    case Money.parse(raw, payment.currency) do
      {:ok, cents} ->
        if cents <= refundable_remaining_cents(payment) do
          {:ok, cents}
        else
          {:error, :exceeds_remaining}
        end

      {:error, :invalid_amount} = error ->
        error
    end
  end

  def parse_refund_amount(_payment, _params), do: {:error, :choose_type}

  @doc """
  Refunds a payment on behalf of the platform, whoever took it.

  Unscoped: this is for system rules that refund without an acting user, such
  as releasing the payment for a request that was never approved. Anything
  acting for a signed-in user must use `issue_host_refund/5` instead.

  `key` is the Stripe idempotency key, as for `issue_host_refund/5`.
  """
  @spec issue_refund(BookingPaymentSchema.t(), integer(), String.t(), String.t() | nil) ::
          {:ok, BookingPaymentSchema.t()} | {:error, refund_error()}
  def issue_refund(payment, amount_cents, key, reason \\ nil) when is_binary(key) do
    refund_locked(
      fn -> BookingPaymentQueries.get_for_update(payment.id) end,
      amount_cents,
      reason,
      key
    )
  end

  @doc """
  Refunds a payment on behalf of the host who took it.

  Only the host whose Stripe account holds the money may refund it. Ownership
  is checked in the locked query, inside the same transaction as the
  validation and the Stripe call, so it cannot change between the check and
  the refund. Another host's payment, an unknown id and a malformed id all
  return `{:error, :not_found}`, so the answer reveals nothing about payments
  the caller does not own.

  `key` is the Stripe idempotency key for this one refund, fixed when the
  refund is decided (a job's id, a dialog's attempt) and carrying the
  amount; see the moduledoc.

  An amount the recorded balance no longer covers may be this very refund,
  made by an attempt that rolled back and since recorded by the
  `charge.refunded` webhook. When the recorded refunds could include it
  (the part a lost dispute took never can), Stripe is asked anyway: a replayed key returns the refund already made,
  which records nothing new, and a fresh one Stripe rejects, which returns
  the local refusal (`:invalid_amount` or `:already_refunded`).
  """
  @spec issue_host_refund(term(), integer(), integer(), String.t(), String.t() | nil) ::
          {:ok, BookingPaymentSchema.t()} | {:error, :not_found | refund_error()}
  def issue_host_refund(payment_id, host_user_id, amount_cents, key, reason \\ nil)
      when is_integer(host_user_id) and is_binary(key) do
    refund_locked(
      fn -> BookingPaymentQueries.get_for_update(payment_id, host_user_id) end,
      amount_cents,
      reason,
      key
    )
  end

  # Run the full validate → Stripe call → DB update sequence inside a
  # serialised transaction with a row lock so that two concurrent host
  # clicks cannot both pass validation against stale `refunded_amount_cents`
  # and issue duplicate refunds via Stripe.
  #
  # The second concurrent caller blocks on the lock, then re-fetches the
  # updated row and re-validates — at which point the remaining refundable
  # balance will reflect the first refund, causing the over-refund attempt
  # to return {:error, :invalid_amount}.
  #
  # `lock_payment` decides which row may be locked at all: the unscoped
  # lookup for system refunds, or the host-scoped one for a host's own.
  defp refund_locked(lock_payment, amount_cents, reason, key) do
    Repo.transaction(fn ->
      with {:ok, locked} <- lock_payment.(),
           :ok <- refusal(locked),
           {:ok, stripe_refund} <- refund_at_stripe(locked, amount_cents, reason, key),
           {:ok, updated_payment} <-
             RefundExecutor.record_refunded(locked, amount_cents, stripe_refund) do
        RefundExecutor.enqueue_refund_email(updated_payment)
        updated_payment
      else
        {:error, rollback_reason} -> Repo.rollback(rollback_reason)
      end
    end)
  end

  defp refund_at_stripe(payment, amount_cents, reason, key) do
    with :ok <- validate_amount(payment, amount_cents),
         :ok <- validate_charge(payment) do
      create_stripe_refund(payment, amount_cents, reason, key)
    else
      {:error, refused} when refused in [:invalid_amount, :already_refunded] ->
        if replayable?(payment, amount_cents),
          do: replay_stripe_refund(payment, amount_cents, reason, key, refused),
          else: {:error, refused}

      {:error, _reason} = error ->
        error
    end
  end

  # A refund already made is part of the recorded refunds, so an amount
  # they cannot hold was never made and needs no Stripe call. A lost
  # dispute's part of the total is no refund Stripe could replay.
  defp replayable?(payment, amount_cents),
    do:
      is_integer(amount_cents) and amount_cents > 0 and
        amount_cents <= RefundedTotal.stripe_refunded_cents(payment)

  # The key may name a refund Stripe already made, which the recorded
  # balance now includes: a replay returns it, and a refund Stripe was
  # never asked for is rejected there as it was here.
  defp replay_stripe_refund(payment, amount_cents, reason, key, refused) do
    with :ok <- validate_charge(payment),
         {:ok, _stripe_refund} = made <- create_stripe_refund(payment, amount_cents, reason, key) do
      made
    else
      {:error, :missing_charge} -> {:error, refused}
      {:error, %Stripe.Error{status: 400, type: "invalid_request_error"}} -> {:error, refused}
      {:error, _reason} = error -> error
    end
  end

  defp validate_amount(%{status: :refunded}, _amount_cents), do: {:error, :already_refunded}

  defp validate_amount(
         %{amount_cents: amount, refunded_amount_cents: refunded},
         amount_cents
       )
       when is_integer(amount_cents) and amount_cents > 0 and
              amount_cents <= amount - refunded,
       do: :ok

  defp validate_amount(_payment, _amount_cents), do: {:error, :invalid_amount}

  defp validate_charge(%{stripe_charge_id: charge}) when is_binary(charge) and charge != "",
    do: :ok

  defp validate_charge(_payment), do: {:error, :missing_charge}

  defp create_stripe_refund(payment, amount_cents, reason, key) do
    payment
    |> RefundExecutor.stripe_params(amount_cents, reason)
    |> StripeRefunds.create(
      connect_account: payment.stripe_account_id,
      idempotency_key: key,
      connect_timeout: @stripe_connect_timeout_ms,
      receive_timeout: @stripe_receive_timeout_ms,
      deadline_ms: @stripe_deadline_ms
    )
  end
end
