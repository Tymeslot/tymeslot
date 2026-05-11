defmodule Tymeslot.MeetingPayments.Refunds do
  @moduledoc """
  Issues refunds against `booking_payments` rows via the Stripe Refund
  API and reconciles the local row.

  The contract for `issue_refund/3`:

    * Validates the payment is within the 60-day refund window.
    * Validates the requested amount is positive and does not exceed
      the remaining refundable balance.
    * Calls Stripe with an idempotency key keyed on the payment id,
      cumulative refunded total after this refund, and the requested
      amount — so a true retry collapses while a fresh attempt at a
      different amount produces a fresh Stripe call.
    * Conditionally passes `refund_application_fee: true` only when
      the original charge had a non-zero application fee. Stripe
      errors if asked to refund a fee that was never collected.
    * Updates the local `booking_payments` row, transitioning status
      to `partially_refunded` or `refunded` based on the new total.
    * Synchronously enqueues an attendee refund email via
      `Tymeslot.Workers.SendBookingPaymentRefunded`.
  """

  require Logger

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.StripeAdapter
  alias Tymeslot.MeetingPayments.Telemetry
  alias Tymeslot.Repo
  alias Tymeslot.Workers.SendBookingPaymentRefunded

  @refund_window_days 60

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
  def refundable_remaining_cents(%{amount_cents: amount, refunded_amount_cents: refunded}),
    do: max(amount - refunded, 0)

  @doc """
  Returns `true` when the payment is in a refundable status and was paid
  within the #{@refund_window_days}-day refund window.

  Encapsulates both the status check and the time-window check so the
  constant has a single source of truth.
  """
  @spec refundable?(BookingPaymentSchema.t()) :: boolean()
  def refundable?(%{status: status} = payment) when status in ["paid", "partially_refunded"],
    do: within_refund_window?(payment)

  def refundable?(_payment), do: false

  defp within_refund_window?(%{paid_at: %DateTime{} = paid_at}),
    do: DateTime.diff(DateTime.utc_now(), paid_at, :day) <= @refund_window_days

  defp within_refund_window?(_payment), do: false

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
    case parse_amount_cents(raw) do
      {:ok, cents} ->
        if cents <= refundable_remaining_cents(payment) do
          {:ok, cents}
        else
          {:error, :exceeds_remaining}
        end

      :error ->
        {:error, :invalid_amount}
    end
  end

  def parse_refund_amount(_payment, _params), do: {:error, :choose_type}

  @spec issue_refund(BookingPaymentSchema.t(), pos_integer(), String.t() | nil) ::
          {:ok, BookingPaymentSchema.t()} | {:error, refund_error()}
  def issue_refund(payment, amount_cents, reason \\ nil) do
    # Run the full validate → Stripe call → DB update sequence inside a
    # serialised transaction with a row lock so that two concurrent host
    # clicks cannot both pass validation against stale `refunded_amount_cents`
    # and issue duplicate refunds via Stripe.
    #
    # The second concurrent caller blocks on the lock, then re-fetches the
    # updated row and re-validates — at which point the remaining refundable
    # balance will reflect the first refund, causing the over-refund attempt
    # to return {:error, :invalid_amount}.
    Repo.transaction(fn ->
      with {:ok, locked} <- BookingPaymentQueries.get_for_update(payment.id),
           :ok <- validate_within_window(locked),
           :ok <- validate_amount(locked, amount_cents),
           :ok <- validate_charge(locked),
           {:ok, _stripe_refund} <- create_stripe_refund(locked, amount_cents, reason),
           {:ok, updated_payment} <- update_payment_after_refund(locked, amount_cents) do
        enqueue_refund_email(updated_payment)
        updated_payment
      else
        {:error, rollback_reason} -> Repo.rollback(rollback_reason)
      end
    end)
  end

  defp validate_within_window(%{paid_at: nil}), do: {:error, :not_paid}

  defp validate_within_window(payment) do
    if within_refund_window?(payment), do: :ok, else: {:error, :outside_refund_window}
  end

  defp validate_amount(%{status: "refunded"}, _amount_cents), do: {:error, :already_refunded}

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

  defp create_stripe_refund(payment, amount_cents, reason) do
    cumulative_after = payment.refunded_amount_cents + amount_cents

    base_params = %{
      charge: payment.stripe_charge_id,
      amount: amount_cents,
      reason: reason,
      metadata: %{
        meeting_id: payment.meeting_id,
        booking_payment_id: payment.id
      }
    }

    params =
      if (payment.application_fee_cents || 0) > 0 do
        Map.put(base_params, :refund_application_fee, true)
      else
        base_params
      end

    StripeAdapter.create_refund(params,
      connect_account: payment.stripe_account_id,
      idempotency_key: "refund:#{payment.id}:#{cumulative_after}:#{amount_cents}"
    )
  end

  defp update_payment_after_refund(payment, amount_cents) do
    new_total = payment.refunded_amount_cents + amount_cents

    new_status =
      cond do
        new_total >= payment.amount_cents -> "refunded"
        new_total > 0 -> "partially_refunded"
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

  defp enqueue_refund_email(payment) do
    case %{booking_payment_id: payment.id}
         |> SendBookingPaymentRefunded.new()
         |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue refund email",
          booking_payment_id: payment.id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp parse_amount_cents(amount) when is_binary(amount) do
    cleaned = amount |> String.replace(",", ".") |> String.trim()

    case Float.parse(cleaned) do
      {decimal, ""} when decimal > 0 -> {:ok, round(decimal * 100)}
      _other -> :error
    end
  end

  defp parse_amount_cents(_amount), do: :error
end
