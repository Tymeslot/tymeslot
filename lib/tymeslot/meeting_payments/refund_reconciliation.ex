defmodule Tymeslot.MeetingPayments.RefundReconciliation do
  @moduledoc """
  What a payment's recorded refunds (`RefundSchema`) need, given the refunds
  Stripe reports for its charge. Pure; `Refunds.reconcile/2` carries the
  plan out.

  A Stripe refund belongs to the row named by its
  `metadata["tymeslot_refund_id"]`, unless that row records a different
  Stripe refund, and otherwise to the row recording its id. Then:

    * a pending row is settled by Stripe's status: `succeeded`, `pending`
      and `requires_action` are money committed at Stripe
      (`:settle_succeeded`), `failed` and `canceled` are not
      (`:settle_failed`);
    * a succeeded row whose refund Stripe reports `failed` or `canceled`
      has the money back with the host (`:fail_after_success`);
    * a failed row whose refund Stripe made is reversed
      (`:settle_succeeded`), unless the row failed because Stripe reported
      that same refund ended: Stripe never revives such a refund, so a
      report saying otherwise is an older one arriving late. A row failed
      on anything else (its attempts ran out, or another attempt's refund
      failed) records no Stripe refund, and is reversed;
    * a committed refund naming a row that records a different Stripe
      refund is a second refund made for that row, the attendee refunded
      twice (`:duplicate`), for a person to put right. Its amount is in the
      charge's refunded total, which `charge.refunded` records, so it is
      counted without a row of its own;
    * a refund belonging to no row is recorded (`:record_external`) only
      when it names neither a row nor a payment, as one a host made in the
      Stripe dashboard does, and only once committed. One naming its
      payment was made by Tymeslot before refunds were recorded, and is
      already in the payment's refunded total.

  Anything else, a row already in the state Stripe reports included, plans
  nothing, so a refund seen twice is acted on once.
  """

  alias Tymeslot.MeetingPayments.RefundSchema

  @committed ["succeeded", "pending", "requires_action"]
  @ended ["failed", "canceled"]

  @type action ::
          {:settle_succeeded, RefundSchema.t(), stripe_refund :: map()}
          | {:settle_failed, RefundSchema.t(), stripe_refund :: map()}
          | {:fail_after_success, RefundSchema.t(), stripe_refund :: map()}
          | {:duplicate, RefundSchema.t(), stripe_refund :: map()}
          | {:record_external, stripe_refund :: map()}

  @doc "Whether Stripe reports `stripe_refund` ended: `failed` or `canceled`."
  @spec ended?(map()) :: boolean()
  def ended?(%{"status" => status}), do: status in @ended
  def ended?(_stripe_refund), do: false

  @doc """
  What `stripe_refunds`, an older report, still count as committed of the
  refunds Stripe has since reported ended: the amounts of those whose row
  failed with Stripe's own verdict. Taken off that report's charge total,
  which counted them then.
  """
  @spec stale_committed_cents([RefundSchema.t()], [map()]) :: non_neg_integer()
  def stale_committed_cents(rows, stripe_refunds)
      when is_list(rows) and is_list(stripe_refunds) do
    stripe_refunds
    |> Enum.filter(&stale_committed?(&1, row_for(&1, rows)))
    |> Enum.reduce(0, &add_amount/2)
  end

  defp add_amount(%{"amount" => amount}, total) when is_integer(amount) and amount >= 0,
    do: total + amount

  @spec plan([RefundSchema.t()], [map()]) :: [action()]
  def plan(rows, stripe_refunds) when is_list(rows) and is_list(stripe_refunds),
    do: Enum.flat_map(stripe_refunds, &plan_refund(&1, rows))

  defp plan_refund(stripe_refund, rows) do
    case row_for(stripe_refund, rows) do
      nil -> unowned(named_row(stripe_refund, rows), stripe_refund)
      row -> action(row, stripe_refund)
    end
  end

  defp row_for(stripe_refund, rows) do
    stripe_id = stripe_refund["id"]

    case metadata(stripe_refund)["tymeslot_refund_id"] do
      row_id when is_binary(row_id) ->
        Enum.find(rows, &(&1.id == row_id and &1.stripe_refund_id in [nil, stripe_id])) ||
          recording(rows, stripe_id)

      _none ->
        recording(rows, stripe_id)
    end
  end

  defp recording(rows, stripe_id) when is_binary(stripe_id),
    do: Enum.find(rows, &(&1.stripe_refund_id == stripe_id))

  defp recording(_rows, _stripe_id), do: nil

  defp named_row(stripe_refund, rows) do
    case metadata(stripe_refund)["tymeslot_refund_id"] do
      row_id when is_binary(row_id) -> Enum.find(rows, &(&1.id == row_id))
      _none -> nil
    end
  end

  defp action(%RefundSchema{status: :pending} = row, %{"status" => status} = refund)
       when status in @committed,
       do: [{:settle_succeeded, row, refund}]

  defp action(%RefundSchema{status: :pending} = row, %{"status" => status} = refund)
       when status in @ended,
       do: [{:settle_failed, row, refund}]

  defp action(%RefundSchema{status: :succeeded} = row, %{"status" => status} = refund)
       when status in @ended,
       do: [{:fail_after_success, row, refund}]

  defp action(
         %RefundSchema{status: :failed, failure_code: code} = row,
         %{"status" => status} = refund
       )
       when status in @committed do
    if ended_by_stripe?(row, code, refund),
      do: [],
      else: [{:settle_succeeded, row, refund}]
  end

  defp action(%RefundSchema{}, _refund), do: []

  # A refund no row owns: `named` is the row its metadata names, which
  # records another Stripe refund, or nil.
  defp unowned(named, %{"id" => id, "status" => status, "amount" => amount} = refund)
       when is_binary(id) and status in @committed and is_integer(amount) and amount > 0,
       do: committed_unowned(named, refund)

  defp unowned(_named, _refund), do: []

  defp committed_unowned(%RefundSchema{} = named, refund), do: [{:duplicate, named, refund}]

  defp committed_unowned(nil, refund) do
    metadata = metadata(refund)

    if is_nil(metadata["tymeslot_refund_id"]) and is_nil(metadata["booking_payment_id"]),
      do: [{:record_external, refund}],
      else: []
  end

  defp stale_committed?(
         %{"status" => status, "amount" => amount} = refund,
         %RefundSchema{status: :failed, failure_code: code} = row
       )
       when status in @committed and is_integer(amount),
       do: ended_by_stripe?(row, code, refund)

  defp stale_committed?(_refund, _row), do: false

  # Whether the row failed because Stripe reported this very refund ended.
  # A row an attempt failed on another refund's verdict records no Stripe
  # refund, so a refund an earlier attempt made still reverses it.
  defp ended_by_stripe?(row, code, refund),
    do: code in RefundSchema.ended_at_stripe_codes() and row.stripe_refund_id == refund["id"]

  defp metadata(%{"metadata" => %{} = metadata}), do: metadata
  defp metadata(_refund), do: %{}
end
