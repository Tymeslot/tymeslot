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
    * a row Tymeslot settled failed without Stripe saying so (its attempts
      ran out, say) whose refund Stripe made is reversed
      (`:settle_succeeded`). A row failed because Stripe reported its
      refund failed stays failed: Stripe never revives such a refund, so a
      report saying otherwise is an older one arriving late;
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

  # The failure codes a refund Stripe ended gets (`RefundOutcome`).
  @ended_at_stripe Enum.map(@ended, &("refund_" <> &1))

  @type action ::
          {:settle_succeeded, RefundSchema.t(), stripe_refund :: map()}
          | {:settle_failed, RefundSchema.t(), stripe_refund :: map()}
          | {:fail_after_success, RefundSchema.t(), stripe_refund :: map()}
          | {:record_external, stripe_refund :: map()}

  @spec plan([RefundSchema.t()], [map()]) :: [action()]
  def plan(rows, stripe_refunds) when is_list(rows) and is_list(stripe_refunds),
    do: Enum.flat_map(stripe_refunds, &(&1 |> row_for(rows) |> action(&1)))

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
       when status in @committed and code not in @ended_at_stripe,
       do: [{:settle_succeeded, row, refund}]

  defp action(%RefundSchema{}, _refund), do: []

  defp action(nil, %{"id" => id, "status" => status, "amount" => amount} = refund)
       when is_binary(id) and status in @committed and is_integer(amount) and amount > 0 do
    metadata = metadata(refund)

    if is_nil(metadata["tymeslot_refund_id"]) and is_nil(metadata["booking_payment_id"]),
      do: [{:record_external, refund}],
      else: []
  end

  defp action(nil, _refund), do: []

  defp metadata(%{"metadata" => %{} = metadata}), do: metadata
  defp metadata(_refund), do: %{}
end
