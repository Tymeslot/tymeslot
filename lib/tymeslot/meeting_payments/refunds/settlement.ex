defmodule Tymeslot.MeetingPayments.Refunds.Settlement do
  @moduledoc """
  Records how a refund ended at Stripe, whoever learnt of it: an attempt
  (`RefundExecutor`) or a webhook (`charge.refunded`, `refund.updated`).

  Every settlement is a conditional update of the refund's row on its
  status, so when an attempt and a webhook learn of one refund together,
  one of them settles it and the other finds it settled
  (`{:ok, refund, :already_settled}`) and does nothing more: the attendee
  is emailed once, and the refunded total moves once.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.RefundedTotal
  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.RefundReconciliation
  alias Tymeslot.MeetingPayments.Refunds.FailureNotice
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.MeetingPayments.Telemetry
  alias Tymeslot.Repo
  alias Tymeslot.Workers.SendBookingPaymentRefunded

  # What a refund's source reports a status change as.
  @status_change_reasons %{
    host: :host_refund,
    cancellation: :cancellation_refund,
    approval_release: :approval_release_refund,
    late_payment: :late_payment_refund,
    series_host: :series_host_refund,
    external: :external_refund
  }

  @type settled :: {:ok, RefundSchema.t(), :settled | :already_settled}

  @doc """
  Records `refund` as made at Stripe as `stripe_refund`, in one short
  transaction under its payment's row lock: the refund is settled
  `succeeded`, its amount added to the payment's refunded total, and the
  attendee's email enqueued. Stripe's total for the charge is used when
  `stripe_refund` carries the charge (`"charge"` as a map with
  `"amount_refunded"`), as it counts the refund once however often it is
  reported; without it the amount is added to the refunds recorded.

  A refund settled `failed` is settled again, since money Stripe moved
  stands, and its reversal is reported (`FailureNotice.reversed/2`). One
  already `succeeded` is `{:ok, refund, :already_settled}` and nothing else
  happens. Returns `{:error, :stripe_refund_taken}` for a Stripe refund
  another row records, and `{:error, :not_found}` for a refund gone.
  """
  @spec settle_succeeded(RefundSchema.t(), map()) :: settled() | {:error, term()}
  def settle_succeeded(%RefundSchema{} = refund, stripe_refund) do
    attrs = %{status: :succeeded, stripe_refund_id: stripe_refund["id"], settled_at: now()}

    recorded =
      Repo.transaction(fn ->
        with {:ok, locked} <- BookingPaymentQueries.get_for_update(refund.booking_payment_id),
             prior = RefundQueries.get_for_update(refund.id),
             {:ok, settled} <- RefundQueries.settle(refund, attrs),
             {:ok, _updated} <-
               record_refunded(
                 locked,
                 refund.amount_cents,
                 stripe_refund,
                 Map.fetch!(@status_change_reasons, refund.source)
               ) do
          enqueue_refund_email(locked)
          {settled, prior}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case recorded do
      {:ok, {settled, %RefundSchema{status: :failed} = failed}} ->
        failure_reversed(failed, settled)
        {:ok, settled, :settled}

      {:ok, {settled, _pending}} ->
        {:ok, settled, :settled}

      {:error, :not_pending} ->
        already_settled(refund)

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Settles a pending `refund` `failed` with `code`, as Stripe reported
  `stripe_refund` ending, and reports it (`FailureNotice.deliver/2`). Not
  fenced by an attempt's claim: Stripe's word decides, whichever attempt
  holds the refund. One already settled is
  `{:ok, refund, :already_settled}`, reported no further.
  """
  @spec settle_failed(RefundSchema.t(), map(), String.t()) :: settled() | {:error, term()}
  def settle_failed(%RefundSchema{} = refund, stripe_refund, code) when is_binary(code) do
    attrs = %{
      status: :failed,
      failure_code: code,
      stripe_refund_id: stripe_refund["id"],
      settled_at: now()
    }

    case RefundQueries.settle_pending(refund, attrs) do
      {:ok, failed} ->
        FailureNotice.deliver(failed, code)
        {:ok, failed, :settled}

      {:error, :not_pending} ->
        already_settled(refund)

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Settles a succeeded `refund` `failed`, once Stripe reports
  `stripe_refund` failed or canceled after accepting it: the money went
  back to the host. In one transaction under the payment's row lock, the
  refund's amount is taken off the payment's refunded total
  (`RefundedTotal.with_refund_failed/2`, the one place the total is
  lowered) and its status follows; then the failure is reported
  (`FailureNotice.deliver/2`), with code `"refund_<status>"`. A refund no
  longer `succeeded` is `{:ok, refund, :already_settled}`.
  """
  @spec fail_after_success(RefundSchema.t(), map()) :: settled() | {:error, term()}
  def fail_after_success(%RefundSchema{} = refund, %{"status" => status}) do
    code = "refund_" <> status

    failed =
      Repo.transaction(fn ->
        with {:ok, locked} <- BookingPaymentQueries.get_for_update(refund.booking_payment_id),
             {:ok, failed} <-
               RefundQueries.fail_succeeded(refund, %{
                 status: :failed,
                 failure_code: code,
                 settled_at: now()
               }),
             {:ok, _updated} <- take_off(locked, refund.amount_cents) do
          failed
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case failed do
      {:ok, failed} ->
        Logger.warning("Refund Stripe accepted has failed; taken off the refunded total",
          refund_id: failed.id,
          booking_payment_id: failed.booking_payment_id,
          failure_code: code
        )

        FailureNotice.deliver(failed, code)
        {:ok, failed, :settled}

      {:error, :not_succeeded} ->
        already_settled(refund)

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Records `stripe_refund`, made of `payment` outside Tymeslot (in the
  Stripe dashboard), as a succeeded `:external` refund, or nothing when it
  is already recorded. Nobody is emailed, and the refunded total is left to
  the charge's own report (`charge.refunded`).
  """
  @spec record_external(BookingPaymentSchema.t(), map()) ::
          {:ok, RefundSchema.t() | nil} | {:error, Ecto.Changeset.t()}
  def record_external(%BookingPaymentSchema{id: payment_id}, stripe_refund) do
    %RefundSchema{}
    |> RefundSchema.external_changeset(%{
      booking_payment_id: payment_id,
      amount_cents: stripe_refund["amount"],
      stripe_refund_id: stripe_refund["id"],
      settled_at: made_at(stripe_refund)
    })
    |> RefundQueries.insert_external()
  end

  @doc """
  Brings `payment`'s recorded refunds in line with `stripe_refunds`, the
  refunds Stripe reports for its charge (`RefundReconciliation.plan/2`),
  one action at a time. A Stripe refund another row records is logged and
  passed over, since no retry changes that; any other failure stops there
  and is returned, for the webhook to be delivered again, and the actions
  already taken find their refunds settled the next time.
  """
  @spec reconcile(BookingPaymentSchema.t(), [map()]) :: :ok | {:error, term()}
  def reconcile(%BookingPaymentSchema{} = payment, stripe_refunds) do
    payment.id
    |> RefundQueries.list_for_payment()
    |> RefundReconciliation.plan(stripe_refunds)
    |> Enum.reduce_while(:ok, fn action, :ok ->
      case carry_out(payment, action) do
        {:error, :stripe_refund_taken} ->
          Logger.error("Stripe refund already recorded on another refund",
            booking_payment_id: payment.id,
            stripe_refund_id: elem(action, 2)["id"]
          )

          {:cont, :ok}

        {:error, _reason} = error ->
          {:halt, error}

        {:ok, _refund} ->
          {:cont, :ok}

        {:ok, _refund, _settled} ->
          {:cont, :ok}
      end
    end)
  end

  defp carry_out(_payment, {:settle_succeeded, refund, stripe_refund}),
    do: settle_succeeded(refund, stripe_refund)

  defp carry_out(_payment, {:settle_failed, refund, %{"status" => status} = stripe_refund}),
    do: settle_failed(refund, stripe_refund, "refund_" <> status)

  defp carry_out(_payment, {:fail_after_success, refund, stripe_refund}),
    do: fail_after_success(refund, stripe_refund)

  defp carry_out(payment, {:record_external, stripe_refund}),
    do: record_external(payment, stripe_refund)

  defp already_settled(%RefundSchema{id: id}) do
    case RefundQueries.get(id) do
      %RefundSchema{} = current -> {:ok, current, :already_settled}
      nil -> {:error, :not_found}
    end
  end

  # Records a refund of `amount_cents` Stripe made of the `locked` payment,
  # as `stripe_refund`: the refunded total and the status that follows from
  # it, whose change is reported to telemetry with `reason`.
  defp record_refunded(locked, amount_cents, stripe_refund, reason) do
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
      Telemetry.emit_status_changed(locked.status, updated.status, reason)
      {:ok, updated}
    end
  end

  defp take_off(locked, amount_cents) do
    new_total = RefundedTotal.with_refund_failed(locked, amount_cents)

    with {:ok, updated} <-
           BookingPaymentQueries.update(locked, %{
             refunded_amount_cents: new_total,
             status: RefundedTotal.status_for(locked, new_total)
           }) do
      Telemetry.emit_status_changed(locked.status, updated.status, :webhook_refund_failed)
      {:ok, updated}
    end
  end

  # Stripe's refunded total for the charge, which counts this refund once
  # however often it is answered, and never below the recorded refunds. A
  # refund without the expanded charge is added to the recorded refunds.
  defp refunded_total(payment, _amount_cents, %{"charge" => %{"amount_refunded" => total}})
       when is_integer(total),
       do: RefundedTotal.with_stripe_refunded(payment, total)

  defp refunded_total(payment, amount_cents, _stripe_refund),
    do: RefundedTotal.with_refund_added(payment, amount_cents)

  # Enqueues the attendee's refund email for `payment`. A failed insert is
  # logged and does not undo the refund.
  defp enqueue_refund_email(payment) do
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

  # Money Stripe moved stands, even over a refund settled failed meanwhile
  # (`RefundQueries.settle/2`); that failure was reported, so its reversal
  # is too, once committed.
  defp failure_reversed(failed, settled) do
    Logger.warning("Refund settled failed was made at Stripe after all; recorded",
      refund_id: settled.id,
      failure_code: failed.failure_code,
      stripe_refund_id: settled.stripe_refund_id
    )

    FailureNotice.reversed(settled, failed.failure_code)
  end

  defp made_at(%{"created" => created}) when is_integer(created),
    do: DateTime.from_unix!(created)

  defp made_at(_stripe_refund), do: now()

  defp now, do: DateTime.utc_now(:second)
end
