defmodule Tymeslot.MeetingPayments.DisputeLossBackfill do
  @moduledoc """
  Rebuilds the refund figures of payments whose dispute was lost before
  `disputed_lost_cents` existed, from what Stripe records.

  Those rows started at 0 and hold a refunded total the older handlers
  wrote as the larger of the refunds and the disputed amount, not their
  sum: a payment refunded 4_000 and then disputed and lost over 3_000
  holds 4_000, not 7_000. `RefundedTotal` reads such a total as refunds
  made at Stripe, so the host may refund more than is left. The loss is on
  no row (Connect webhook payloads are not kept), but Stripe lists a
  charge's disputes, and the charge's `amount_refunded` counts its refunds
  alone. From the two each row gets what a loss recorded today gives it
  (`RefundedTotal.with_dispute_lost/2`): the dispute's share, a refunded
  total of refunds plus that share within the amount paid, and the status
  that total implies. The total is never lowered.

  An operator runs this once per deployment that takes payments, through
  `Tymeslot.Release.backfill_dispute_losses/1`; it is never run at boot,
  since it calls the deployment's own Stripe account.

  The candidates are payments with a charge, something refunded, no loss
  recorded, and status `refunded` or `partially_refunded`. Every release
  that handled disputes left a lost one in one of those two statuses. The
  dispute markers (`stripe_dispute_id`, `dispute_closed_at`) cannot narrow
  it further: disputes closed before those columns existed carry none. A
  `disputed` row is left out: its dispute is still open, or its close
  never reached the row, and the dispute webhook records either.

  Each candidate costs one Stripe call to list its disputes, and one more
  to read the charge when one was lost; a payment with no lost dispute is
  left as it is. The write is guarded on `disputed_lost_cents = 0` and on
  the refunded total read, so a second run, or a webhook changing the row
  meanwhile, writes nothing. No transaction or row lock is held across a
  Stripe call: candidates are read a page at a time by id.
  """

  alias Tymeslot.Integrations.Stripe.Charges
  alias Tymeslot.Integrations.Stripe.Disputes
  alias Tymeslot.Integrations.Stripe.Pagination
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.RefundedTotal

  @page_size 100

  @type correction :: %{
          disputed_lost_cents: pos_integer(),
          refunded_amount_cents: pos_integer(),
          status: BookingPaymentSchema.status()
        }

  @type outcome ::
          {:recorded | :would_record | :unchanged, BookingPaymentSchema.t(), correction()}
          | {:error, BookingPaymentSchema.t(), term()}

  @type summary :: %{
          candidates: non_neg_integer(),
          lost: non_neg_integer(),
          updated: non_neg_integer(),
          clamped: non_neg_integer(),
          unchanged: non_neg_integer(),
          errors: [{Ecto.UUID.t(), term()}]
        }

  @doc """
  Reads every candidate's disputes from Stripe and rebuilds the refund
  figures of those with a lost one. Options:

    * `:dry_run` (default `true`): read from Stripe, write nothing, and
      count what would be corrected as `lost`;
    * `:pause_ms` (default 100): the pause between candidates;
    * `:limit` (default `nil`, every candidate): how many candidates to read;
    * `:on_outcome`: called with each payment's `t:outcome/0` other than
      "no lost dispute", for reporting.

  `lost` counts payments with a lost dispute, `updated` those written,
  `clamped` those whose loss was cut to the amount paid, `unchanged` those
  another process changed first. A failed Stripe call goes into `errors`
  with the payment id, and the run carries on.
  """
  @spec run(keyword()) :: summary()
  def run(opts \\ []) do
    opts =
      Keyword.validate!(opts,
        dry_run: true,
        pause_ms: 100,
        limit: nil,
        on_outcome: fn _outcome -> :ok end
      )

    candidates()
    |> maybe_take(opts[:limit])
    |> Stream.with_index()
    |> Enum.reduce(empty_summary(), fn {payment, index}, summary ->
      if index > 0, do: pause(opts[:pause_ms])
      tally(summary, payment, backfill(payment, opts), opts[:on_outcome])
    end)
    |> Map.update!(:errors, &Enum.reverse/1)
  end

  @doc """
  What `payment` should record given its charge's `disputes` and `charge`
  as Stripe returns them: `:none` without a lost dispute, otherwise
  `{:lost, correction}`, or `{:clamped, correction}` when the lost
  disputes add up to more than the amount paid and the share is cut to it.

  The refunded total is the charge's refunds plus the loss, within the
  amount paid (`RefundedTotal.with_dispute_lost/2`), and never below the
  total `payment` holds.
  """
  @spec correction(BookingPaymentSchema.t(), [map()], map()) ::
          :none | {:lost | :clamped, correction()}
  def correction(payment, disputes, %{"amount_refunded" => stripe_refunded})
      when is_list(disputes) and is_integer(stripe_refunded) do
    case lost_sum(disputes) do
      0 ->
        :none

      sum ->
        recorded =
          RefundedTotal.with_dispute_lost(
            %{payment | refunded_amount_cents: stripe_refunded, disputed_lost_cents: 0},
            sum
          )

        whole = max(payment.refunded_amount_cents, recorded.refunded_amount_cents)
        lost = min(recorded.disputed_lost_cents, whole)
        kind = if lost < sum, do: :clamped, else: :lost

        {kind,
         %{
           disputed_lost_cents: lost,
           refunded_amount_cents: whole,
           status: RefundedTotal.status_for(payment, whole)
         }}
    end
  end

  defp lost_sum(disputes) do
    disputes
    |> Enum.filter(&match?(%{"status" => "lost"}, &1))
    |> Enum.map(&Map.fetch!(&1, "amount"))
    |> Enum.sum()
  end

  defp candidates do
    Stream.resource(
      fn -> nil end,
      fn after_id ->
        case BookingPaymentQueries.dispute_loss_candidates(after_id, @page_size) do
          [] -> {:halt, after_id}
          page -> {page, List.last(page).id}
        end
      end,
      fn _cursor -> :ok end
    )
  end

  defp maybe_take(stream, nil), do: stream

  defp maybe_take(stream, limit) when is_integer(limit) and limit >= 0,
    do: Stream.take(stream, limit)

  defp pause(ms) when ms > 0, do: Process.sleep(ms)
  defp pause(_ms), do: :ok

  defp backfill(payment, opts) do
    stripe_opts = [connect_account: payment.stripe_account_id]

    with {:ok, disputes} <-
           Pagination.collect(&Disputes.list/2, %{charge: payment.stripe_charge_id}, stripe_opts) do
      if lost_sum(disputes) > 0 do
        with {:ok, charge} <- Charges.retrieve(payment.stripe_charge_id, stripe_opts) do
          record(payment, correction(payment, disputes, charge), opts)
        end
      else
        :none
      end
    end
  end

  defp record(_payment, :none, _opts), do: :none

  defp record(payment, {_kind, correction} = result, opts) do
    if opts[:dry_run] do
      {:would_record, result}
    else
      {:ok, written} = BookingPaymentQueries.record_dispute_loss(payment, correction)
      {written, result}
    end
  end

  defp empty_summary,
    do: %{candidates: 0, lost: 0, updated: 0, clamped: 0, unchanged: 0, errors: []}

  defp tally(summary, payment, result, on_outcome) do
    summary = %{summary | candidates: summary.candidates + 1}

    case result do
      :none ->
        summary

      {:error, reason} ->
        on_outcome.({:error, payment, reason})
        %{summary | errors: [{payment.id, reason} | summary.errors]}

      {written, {kind, correction}} ->
        on_outcome.({written, payment, correction})

        summary
        |> Map.update!(:lost, &(&1 + 1))
        |> bump(:clamped, kind == :clamped)
        |> bump(:updated, written == :recorded)
        |> bump(:unchanged, written == :unchanged)
    end
  end

  defp bump(summary, key, true), do: Map.update!(summary, key, &(&1 + 1))
  defp bump(summary, _key, false), do: summary
end
