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
  `succeeded`, the payment's refunded total raised to Stripe's total for
  the charge, and the attendee's email enqueued. `stripe_refund` must
  carry its charge expanded (`"charge"` as a map with `"amount_refunded"`):
  Stripe's total counts the refund once however often it is reported,
  where adding its amount would count it again on top of a total that
  already holds it. Without it nothing is recorded and
  `{:error, :charge_not_expanded}` is returned.

  A refund settled `failed` is settled again, since money Stripe moved
  stands, and its reversal is reported (`FailureNotice.reversed/2`),
  unless Stripe itself reported it ended: then `stripe_refund` is the
  older word. One already `succeeded`, or failed by Stripe, is
  `{:ok, refund, :already_settled}` and nothing else happens. Returns `{:error, :stripe_refund_taken}` for a Stripe refund
  another row records, and `{:error, :not_found}` for a refund gone.
  """
  @spec settle_succeeded(RefundSchema.t(), map()) :: settled() | {:error, term()}
  def settle_succeeded(%RefundSchema{} = refund, stripe_refund) do
    with {:ok, charge_total} <- charge_total(stripe_refund, refund.booking_payment_id),
         do: record_succeeded(refund, stripe_refund, charge_total)
  end

  defp record_succeeded(refund, stripe_refund, charge_total) do
    attrs = %{status: :succeeded, stripe_refund_id: stripe_refund["id"], settled_at: now()}

    recorded =
      Repo.transaction(fn ->
        with {:ok, locked} <- BookingPaymentQueries.get_for_update(refund.booking_payment_id),
             prior = RefundQueries.get_for_update(refund.id),
             {:ok, settled} <- RefundQueries.settle(refund, attrs),
             {:ok, _updated} <-
               record_refunded(
                 locked,
                 charge_total,
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
  is already recorded. In one transaction under the payment's row lock the
  refunded total is raised to Stripe's total for the charge, as for
  `settle_succeeded/2`, so a later failure of the refund
  (`fail_after_success/2`) takes off money that was counted. Nobody is
  emailed. `stripe_refund` must carry its charge expanded, or nothing is
  recorded and `{:error, :charge_not_expanded}` is returned.
  """
  @spec record_external(BookingPaymentSchema.t(), map()) ::
          {:ok, RefundSchema.t() | nil} | {:error, term()}
  def record_external(%BookingPaymentSchema{id: payment_id}, stripe_refund) do
    changeset =
      RefundSchema.external_changeset(%RefundSchema{}, %{
        booking_payment_id: payment_id,
        amount_cents: stripe_refund["amount"],
        stripe_refund_id: stripe_refund["id"],
        settled_at: made_at(stripe_refund)
      })

    with {:ok, charge_total} <- charge_total(stripe_refund, payment_id) do
      Repo.transaction(fn ->
        with {:ok, locked} <- BookingPaymentQueries.get_for_update(payment_id),
             {:ok, %RefundSchema{} = recorded} <- RefundQueries.insert_external(changeset),
             {:ok, _updated} <- record_refunded(locked, charge_total, :external_refund) do
          recorded
        else
          {:ok, nil} -> nil
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
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

  @doc """
  What `stripe_refunds`, as an older report of `payment`'s charge shows
  them, still count as committed of refunds Stripe has since reported
  ended (`RefundReconciliation.stale_committed_cents/2`).
  """
  @spec stale_committed_cents(BookingPaymentSchema.t(), [map()]) :: non_neg_integer()
  def stale_committed_cents(%BookingPaymentSchema{id: id}, stripe_refunds),
    do:
      id
      |> RefundQueries.list_for_payment()
      |> RefundReconciliation.stale_committed_cents(stripe_refunds)

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

  # Records a refund Stripe made of the `locked` payment, its charge
  # showing `charge_total` refunded: the refunded total, never below the
  # refunds already recorded, and the status that follows from it
  # (`RefundedTotal.status_for/2`, under which an open dispute stands),
  # whose change is reported to telemetry with `reason`.
  defp record_refunded(locked, charge_total, reason) do
    new_total = RefundedTotal.with_stripe_refunded(locked, charge_total)

    with {:ok, updated} <-
           BookingPaymentQueries.update(locked, %{
             refunded_amount_cents: new_total,
             status: RefundedTotal.status_for(locked, new_total)
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

  # Stripe's refunded total for the refund's charge. Every caller asks for
  # the charge expanded, so its absence is a fault, refused rather than
  # guessed at.
  defp charge_total(%{"charge" => %{"amount_refunded" => total}}, _payment_id)
       when is_integer(total),
       do: {:ok, total}

  defp charge_total(stripe_refund, payment_id) do
    Logger.error("Stripe refund without its charge expanded; not recorded",
      booking_payment_id: payment_id,
      stripe_refund_id: stripe_refund["id"]
    )

    {:error, :charge_not_expanded}
  end

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
