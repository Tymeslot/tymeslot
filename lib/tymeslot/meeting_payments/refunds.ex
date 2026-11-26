defmodule Tymeslot.MeetingPayments.Refunds do
  @moduledoc """
  Refunds of `booking_payments` rows: what may be refunded, and recording a
  refund for `RefundExecutor` to make at Stripe.

  `request_refund/4` records a refund (`RefundSchema`) under the payment's
  row lock, with no Stripe call, and with it a job that makes it
  (`Workers.ExecuteRefund`). `execute/2` makes one attempt outside any
  transaction (`RefundExecutor`), and `refund_now/4` does both, for a caller
  that waits on the answer. A pending refund counts against the refundable
  balance until it settles, so a second refund cannot spend the same money.

  How a refund ended at Stripe is recorded by `Refunds.Settlement`, for an
  attempt and for the refund webhooks alike (`reconcile/2`), so each refund
  settles once.

  A payment `refusal/1` rules out is refused before anything is recorded:
  one never paid (`:not_paid`), one past the 60-day refund window
  (`:outside_refund_window`), and one Stripe holds for a dispute
  (`:under_dispute`). The one exception is `request_remaining_refund/2`
  under a dispute, which records the refund already failed, so the
  dispute's close can tell it was owed.
  """

  alias Ecto.Changeset
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.Money
  alias Tymeslot.MeetingPayments.RefundedTotal
  alias Tymeslot.MeetingPayments.RefundExecutor
  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.Refunds.Settlement
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.MeetingPayments.Workers.ExecuteRefund
  alias Tymeslot.Repo

  require Logger

  @refund_window_days 60

  # The failure code of a refund recorded while a dispute held the money
  # (`request_remaining_refund/2`).
  @held_by_dispute "under_dispute"

  # How long the Stripe call of `refund_now/4` may take: someone waits on it.
  @interactive_deadline_ms 10_000

  # A requested refund's safety job runs this long after the request, by
  # when a caller making the refund itself has normally settled it.
  @safety_delay_seconds 120

  # `RefundSchema.requestable_sources/0`, written out so that reading it
  # adds no compile-time dependency on the schema; a test keeps the two
  # lists the same.
  @requestable_sources [:host, :cancellation, :approval_release, :late_payment, :series_host]

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

  @typedoc "How an attempt at a recorded refund ended (`execute/2`)."
  @type attempt_result ::
          {:ok | :pending | :stuck, RefundSchema.t()} | {:error, refusal() | :refund_failed}

  @doc """
  Returns the remaining refundable balance in cents for a booking payment:
  what is neither refunded nor in a pending refund
  (`RefundedTotal.refundable_cents/2`, `pending_refund_cents/1`).
  """
  @spec refundable_remaining_cents(BookingPaymentSchema.t()) :: non_neg_integer()
  def refundable_remaining_cents(payment),
    do: RefundedTotal.refundable_cents(payment, pending_refund_cents(payment))

  @doc """
  What the payment's pending refunds add up to, in cents: its
  `pending_refund_cents`, as the host-facing queries fill it in, or, for a
  payment loaded without it, looked up by its id, once.
  """
  @spec pending_refund_cents(BookingPaymentSchema.t()) :: non_neg_integer()
  def pending_refund_cents(%{pending_refund_cents: pending}) when is_integer(pending),
    do: pending

  def pending_refund_cents(%{id: id}) when is_binary(id), do: RefundQueries.pending_cents(id)
  def pending_refund_cents(_payment), do: 0

  @doc "Whether a refund of the payment is recorded and not yet settled."
  @spec refund_pending?(BookingPaymentSchema.t()) :: boolean()
  def refund_pending?(payment), do: pending_refund_cents(payment) > 0

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

  Raises, rolling the transaction back, when the refund or its job cannot
  be inserted: the checks above leave nothing the row's constraints refuse,
  so that is a fault, not a refusal to report.

  Options:

    * `:host_user_id`: the host acting. Only a payment they took is found,
      decided under the lock; any other is `{:error, :not_found}`. Recorded
      as who asked.
    * `:reason`: the Stripe `reason` param.
    * `:legacy_idempotency_key` and `:legacy_since`, given together: a key
      the refund may already have been sent under elsewhere, and when it
      could first have been. The attempts replay it while Stripe keeps it
      (`RefundExecutor`).
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
        :legacy_since,
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
  Records a refund of whatever `payment` has left to refund, decided by
  `source`, with its job enqueued to run at once (`request_refund/4`), for
  a refund the attendee is owed in full and nobody waits on.

  A payment with nothing left, or one `refusal/1` rules out, records no
  refund to make and returns `{:ok, :none}`: the money stays on the host's
  outstanding refunds. A payment under dispute still records the refund,
  settled `failed` with code `#{@held_by_dispute}` and never sent to Stripe,
  which refuses to refund a disputed charge: that is the row an attempt
  leaves when the dispute opens after the refund was recorded, so whichever
  came first, the dispute's close finds the refund was owed
  (`Webhooks.ChargeDisputeClosed`). All of this is checked before
  `request_refund/4`, whose refusal would abort a transaction the caller
  holds, so `payment` must be current (as under its row lock); its pending
  refunds are read afresh.

  `host_user_id:`, when given, is recorded as who asked, as
  `request_refund/4` records it.
  """
  @spec request_remaining_refund(BookingPaymentSchema.t(), refund_source(), keyword()) ::
          {:ok, RefundSchema.t() | :none} | {:error, refusal()}
  def request_remaining_refund(%BookingPaymentSchema{} = payment, source, opts \\ [])
      when source in @requestable_sources do
    opts = Keyword.validate!(opts, [:host_user_id])
    remaining = RefundedTotal.refundable_cents(payment, RefundQueries.pending_cents(payment.id))
    request_remaining(payment, remaining, source, refusal(payment), opts)
  end

  @doc """
  Locks the payment `payment_id` taken by `host_user_id`, then records a
  refund of whatever it has left, asked by that host
  (`request_remaining_refund/3`), for a caller whose transaction holds no
  lock on it yet. Sized under the lock, so a refund or dispute that landed
  since the caller last read the payment is accounted for rather than
  refused. Another host's payment, or one that does not exist, is
  `{:error, :not_found}`.
  """
  @spec request_remaining_refund_locked(Ecto.UUID.t(), integer(), refund_source()) ::
          {:ok, RefundSchema.t() | :none} | {:error, refusal()}
  def request_remaining_refund_locked(payment_id, host_user_id, source)
      when is_integer(host_user_id) do
    with {:ok, payment} <- lock(payment_id, host_user_id),
         do: request_remaining_refund(payment, source, host_user_id: host_user_id)
  end

  defp request_remaining(_payment, remaining, _source, _refusal, _opts) when remaining <= 0,
    do: {:ok, :none}

  defp request_remaining(payment, remaining, source, :ok, opts),
    do: request_refund(payment, remaining, source, [enqueue_now: true] ++ opts)

  defp request_remaining(payment, remaining, source, {:error, :under_dispute}, opts) do
    %RefundSchema{}
    |> RefundSchema.request_changeset(%{
      booking_payment_id: payment.id,
      amount_cents: remaining,
      source: source,
      requested_by_user_id: opts[:host_user_id]
    })
    |> Changeset.change(
      status: :failed,
      failure_code: @held_by_dispute,
      settled_at: DateTime.utc_now(:second)
    )
    |> RefundQueries.insert!()

    Logger.info("Refund held back by a dispute, recorded for the dispute's close",
      booking_payment_id: payment.id,
      source: source
    )

    {:ok, :none}
  end

  defp request_remaining(payment, _remaining, source, {:error, reason}, _opts) do
    Logger.warning("Refund cannot be made automatically, left to the host",
      booking_payment_id: payment.id,
      source: source,
      reason: reason
    )

    {:ok, :none}
  end

  @doc """
  Makes one attempt at a recorded refund, outside any transaction; see
  `RefundExecutor.run/2` for the steps and options. Returns the refund once
  it succeeded, `{:pending, refund}` while it waits for another attempt,
  `{:error, :refund_failed}` once it failed, `{:error, :missing_charge}`
  when the last attempt found no charge to refund, and `{:stuck, refund}`
  when Stripe refuses to list the charge's refunds: the refund stays
  pending, reported, and its `Workers.ExecuteRefund` job snoozes and tries
  again, up to a day apart, until it is settled.
  """
  @spec execute(RefundSchema.t(), keyword()) :: attempt_result()
  defdelegate execute(refund, opts), to: RefundExecutor, as: :run

  @doc """
  Records `refund` as made at Stripe; see `Refunds.Settlement.settle_succeeded/2`.
  """
  @spec settle_succeeded(RefundSchema.t(), map()) :: Settlement.settled() | {:error, term()}
  defdelegate settle_succeeded(refund, stripe_refund), to: Settlement

  @doc """
  Settles a pending refund failed as Stripe reported it; see
  `Refunds.Settlement.settle_failed/3`.
  """
  @spec settle_failed(RefundSchema.t(), map(), String.t()) ::
          Settlement.settled() | {:error, term()}
  defdelegate settle_failed(refund, stripe_refund, code), to: Settlement

  @doc """
  Settles a pending refund no attempt can from what an operator read off
  Stripe's dashboard; see `Refunds.Settlement.settle_by_hand/2`.
  """
  @spec settle_by_hand(RefundSchema.t(), term()) :: Settlement.settled() | {:error, term()}
  defdelegate settle_by_hand(refund, outcome), to: Settlement

  @doc """
  Brings a payment's recorded refunds in line with the refunds Stripe
  reports for its charge, for the refund webhooks; see
  `Refunds.Settlement.reconcile/2`.
  """
  @spec reconcile(BookingPaymentSchema.t(), [map()]) :: :ok | {:error, term()}
  defdelegate reconcile(payment, stripe_refunds), to: Settlement

  @doc """
  What an older report of a payment's charge refunds still counts as
  committed of refunds Stripe has since reported ended; see
  `Refunds.Settlement.stale_committed_cents/2`.
  """
  @spec stale_committed_cents(BookingPaymentSchema.t(), [map()]) :: non_neg_integer()
  defdelegate stale_committed_cents(payment, stripe_refunds), to: Settlement

  @doc """
  Records a refund (`request_refund/4`) and makes its first attempt at once
  (`execute/2`), for a caller waiting on the outcome.
  """
  @spec refund_now(BookingPaymentSchema.t(), pos_integer(), refund_source(), keyword()) ::
          attempt_result()
  def refund_now(payment, amount_cents, source, opts) do
    with {:ok, refund} <- request_refund(payment, amount_cents, source, opts),
         do: execute(refund, deadline_ms: @interactive_deadline_ms)
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
        legacy_idempotency_key: opts[:legacy_idempotency_key],
        legacy_since: opts[:legacy_since]
      })

    schedule_in =
      if opts[:enqueue_now], do: 0, else: opts[:schedule_in] || @safety_delay_seconds

    refund = RefundQueries.insert!(changeset)
    Oban.insert!(ExecuteRefund.new(%{refund_id: refund.id}, schedule_in: schedule_in))
    {:ok, refund}
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
  them first. `request_refund/4` applies them too.
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
  Parses raw refund-form params into `{:ok, cents}` or a tagged
  `{:error, atom()}`.

  Accepts the standard `"refund_type"` param shape used by the payments UI:

    * `%{"refund_type" => "full"}` — issues the full remaining balance
    * `%{"refund_type" => "partial", "amount" => "15.00"}` — decimal string,
      commas normalised to periods

  Error atoms:
    * `:choose_type` — `refund_type` key is absent or unrecognised
    * `:invalid_amount` — amount string cannot be parsed or is not positive
    * `:exceeds_remaining` — parsed amount exceeds the remaining balance
    * `:refund_in_progress` — a full refund of a payment whose pending
      refunds hold all that remains
  """
  @spec parse_refund_amount(BookingPaymentSchema.t(), map()) ::
          {:ok, non_neg_integer()}
          | {:error, :invalid_amount | :exceeds_remaining | :choose_type | :refund_in_progress}
  def parse_refund_amount(payment, %{"refund_type" => "full"}) do
    case refundable_remaining_cents(payment) do
      0 -> if refund_pending?(payment), do: {:error, :refund_in_progress}, else: {:ok, 0}
      remaining -> {:ok, remaining}
    end
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
end
