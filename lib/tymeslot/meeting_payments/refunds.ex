defmodule Tymeslot.MeetingPayments.Refunds do
  @moduledoc """
  Issues refunds against `booking_payments` rows via the Stripe Refund
  API and reconciles the local row.

  The contract shared by `issue_refund/3` (system refunds, unscoped) and
  `issue_host_refund/4` (a host refunding a payment they took):

    * Refuses a payment `refusal/1` rules out, before any Stripe call:
      one never paid (`:not_paid`), one past the 60-day refund window
      (`:outside_refund_window`), and one Stripe holds for a dispute
      (`:under_dispute`).
    * Validates the requested amount is positive and does not exceed
      the remaining refundable balance.
    * Calls Stripe with an idempotency key keyed on the payment id,
      cumulative refunded total after this refund, and the requested
      amount — so a true retry collapses while a fresh attempt at a
      different amount produces a fresh Stripe call. A host refund may be
      given the caller's own key instead (`issue_host_refund/5`).
    * Conditionally passes `refund_application_fee: true` only when
      the original charge had a non-zero application fee. Stripe
      errors if asked to refund a fee that was never collected.
    * Updates the local `booking_payments` row, transitioning status
      to `partially_refunded` or `refunded` based on the new total. The
      new total is Stripe's own refunded total for the charge, read from
      the refund's expanded charge and never lowering the recorded one
      (the `charge.refunded` webhook's rule), so a refund Stripe answers
      again for a replayed key is not counted twice.
    * Synchronously enqueues an attendee refund email via
      `Tymeslot.Workers.SendBookingPaymentRefunded`.
  """

  require Logger

  alias Stripe.Error, as: StripeError
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.Money
  alias Tymeslot.MeetingPayments.StripeAdapter
  alias Tymeslot.MeetingPayments.Telemetry
  alias Tymeslot.Repo
  alias Tymeslot.Workers.SendBookingPaymentRefunded

  @refund_window_days 60

  # The refund call runs while its transaction holds the payment's row lock,
  # so it is bounded tighter than hackney's defaults (8_000 ms to connect,
  # 5_000 ms per receive). stripity_stripe passes these through to hackney
  # and retries a timed-out request up to three more times, with at most
  # 2_000 ms between attempts, safely under the same idempotency key: four
  # attempts at 3_000 + 5_000 ms plus 3_500 ms of backoff bound the call at
  # about 35 seconds instead of about 55.
  @stripe_connect_timeout_ms 3_000
  @stripe_recv_timeout_ms 5_000

  @type refund_error ::
          :not_paid
          | :outside_refund_window
          | :already_refunded
          | :under_dispute
          | :invalid_amount
          | :missing_charge
          | term()

  @doc """
  Returns the remaining refundable balance in cents for a booking payment.

  Computes `max(amount_cents - refunded_amount_cents, 0)`.
  """
  @spec refundable_remaining_cents(BookingPaymentSchema.t()) :: non_neg_integer()
  def refundable_remaining_cents(%{amount_cents: amount, refunded_amount_cents: refunded})
      when is_integer(amount) and is_integer(refunded),
      do: max(amount - refunded, 0)

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
  them first. `issue_refund/3` and `issue_host_refund/4` apply them too.
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
  acting for a signed-in user must use `issue_host_refund/4` instead.
  """
  @spec issue_refund(BookingPaymentSchema.t(), pos_integer(), String.t() | nil) ::
          {:ok, BookingPaymentSchema.t()} | {:error, refund_error()}
  def issue_refund(payment, amount_cents, reason \\ nil) do
    refund_locked(
      fn -> BookingPaymentQueries.get_for_update(payment.id) end,
      amount_cents,
      reason,
      nil
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

  `opts` takes `:idempotency_key`, the Stripe key to refund under instead
  of the one derived from the payment's refunded total. For a caller that
  retries one refund across transactions while other refunds of the same
  payment may land in between (a job, keyed on its id): the derived key
  changes with the total, so a retry after Stripe accepted the refund but
  the transaction recording it rolled back would refund again, where the
  caller's own key gets that same refund back. Stripe keeps a key for at
  least 24 hours, so the caller's retries must end inside that.

  Under the caller's key, an amount the recorded balance no longer covers
  may be that very refund, made by an attempt that rolled back and since
  recorded by the `charge.refunded` webhook. So Stripe is asked anyway: a
  replayed key returns the refund already made, which records nothing new,
  and a fresh one Stripe rejects, which returns the local refusal
  (`:invalid_amount` or `:already_refunded`) as before.
  """
  @spec issue_host_refund(term(), integer(), pos_integer(), String.t() | nil, keyword()) ::
          {:ok, BookingPaymentSchema.t()} | {:error, :not_found | refund_error()}
  def issue_host_refund(payment_id, host_user_id, amount_cents, reason \\ nil, opts \\ [])
      when is_integer(host_user_id) do
    refund_locked(
      fn -> BookingPaymentQueries.get_for_update(payment_id, host_user_id) end,
      amount_cents,
      reason,
      Keyword.get(opts, :idempotency_key)
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
  # `key` is the caller's Stripe idempotency key, or nil for the derived one.
  defp refund_locked(lock_payment, amount_cents, reason, key) do
    Repo.transaction(fn ->
      with {:ok, locked} <- lock_payment.(),
           :ok <- refusal(locked),
           {:ok, stripe_refund} <- refund_at_stripe(locked, amount_cents, reason, key),
           {:ok, updated_payment} <-
             update_payment_after_refund(locked, amount_cents, stripe_refund) do
        enqueue_refund_email(updated_payment)
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
      {:error, refused} when refused in [:invalid_amount, :already_refunded] and is_binary(key) ->
        replay_stripe_refund(payment, amount_cents, reason, key, refused)

      {:error, _reason} = error ->
        error
    end
  end

  # The caller's key may name a refund Stripe already made, which the
  # recorded balance now includes: a replay returns it, and a refund Stripe
  # was never asked for is rejected there as it was here.
  defp replay_stripe_refund(payment, amount_cents, reason, key, refused) do
    with :ok <- validate_charge(payment),
         {:ok, _stripe_refund} = made <- create_stripe_refund(payment, amount_cents, reason, key) do
      made
    else
      {:error, :missing_charge} -> {:error, refused}
      {:error, %StripeError{source: :stripe, code: :invalid_request_error}} -> {:error, refused}
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
    params =
      %{
        charge: payment.stripe_charge_id,
        amount: amount_cents,
        metadata: refund_metadata(payment),
        expand: ["charge"]
      }
      |> maybe_put_reason(reason)
      |> maybe_refund_application_fee(payment)

    StripeAdapter.create_refund(params,
      connect_account: payment.stripe_account_id,
      idempotency_key: key || derived_idempotency_key(payment, amount_cents),
      connect_timeout: @stripe_connect_timeout_ms,
      recv_timeout: @stripe_recv_timeout_ms
    )
  end

  defp derived_idempotency_key(payment, amount_cents) do
    cumulative_after = payment.refunded_amount_cents + amount_cents
    "refund:#{payment.id}:#{cumulative_after}:#{amount_cents}"
  end

  # A series payment names its series instead of a meeting.
  defp refund_metadata(%{series_id: series_id} = payment) when is_binary(series_id),
    do: %{series_id: series_id, booking_payment_id: payment.id}

  defp refund_metadata(payment),
    do: %{meeting_id: payment.meeting_id, booking_payment_id: payment.id}

  # Stripe rejects a blank `reason` ("cannot be unset") — only include it when
  # the caller supplies a non-empty value, otherwise omit the param entirely.
  defp maybe_put_reason(params, reason) when is_binary(reason) and reason != "",
    do: Map.put(params, :reason, reason)

  defp maybe_put_reason(params, _reason), do: params

  defp maybe_refund_application_fee(params, %{application_fee_cents: fee})
       when is_integer(fee) and fee > 0,
       do: Map.put(params, :refund_application_fee, true)

  defp maybe_refund_application_fee(params, _payment), do: params

  defp update_payment_after_refund(payment, amount_cents, stripe_refund) do
    new_total = refunded_total(payment, amount_cents, stripe_refund)

    new_status =
      cond do
        new_total >= payment.amount_cents -> :refunded
        new_total > 0 -> :partially_refunded
        true -> payment.status
      end

    case BookingPaymentQueries.update(payment, %{
           refunded_amount_cents: new_total,
           status: new_status
         }) do
      {:ok, updated} = result ->
        Telemetry.emit_status_changed(payment.status, updated.status, :host_refund)
        result

      {:error, _changeset} = err ->
        err
    end
  end

  # Stripe's refunded total for the charge, which counts this refund once
  # however often its key is replayed, and never below the recorded total
  # (the webhook's rule). A response without the expanded charge falls back
  # to adding the refund to the recorded total.
  defp refunded_total(payment, _amount_cents, %{charge: %{amount_refunded: stripe_total}})
       when is_integer(stripe_total),
       do: max(payment.refunded_amount_cents, stripe_total)

  defp refunded_total(payment, amount_cents, _stripe_refund),
    do: payment.refunded_amount_cents + amount_cents

  defp enqueue_refund_email(payment) do
    case %{booking_payment_id: payment.id}
         |> SendBookingPaymentRefunded.new()
         |> Oban.insert() do
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
end
