defmodule Tymeslot.MeetingPayments.DisputeLossBackfill do
  @moduledoc """
  Records `disputed_lost_cents` for payments whose dispute was lost before
  the column existed, reading the loss from Stripe.

  Those rows started at 0 although `refunded_amount_cents` already holds
  what the dispute took, so `RefundedTotal` reads that share as refunds
  made at Stripe. The amount is on no row (Connect webhook payloads are not
  kept), but Stripe lists a charge's disputes with their status and amount.
  An operator runs this once per deployment that takes payments, through
  `Tymeslot.Release.backfill_dispute_losses/1`; it is never run at boot,
  since it calls the deployment's own Stripe account.

  The candidates are payments with a charge, something refunded, no loss
  recorded, and status `refunded` or `partially_refunded`. Every release
  that handled disputes left a lost one in one of those two statuses,
  derived from a refunded total that already counts the loss. The dispute
  markers (`stripe_dispute_id`, `dispute_closed_at`) cannot narrow it
  further: disputes closed before those columns existed carry none. A
  `disputed` row is left out: its dispute is still open, or its close
  never reached the row, and either way its refunded total holds no loss
  this could pick out.

  Each candidate costs one Stripe list call; a payment with no lost
  dispute is left as it is. The write is guarded on `disputed_lost_cents =
  0`, so a second run, or a dispute webhook recording the loss meanwhile,
  writes nothing more. No transaction or row lock is held across a Stripe
  call: candidates are read a page at a time by id.
  """

  alias Tymeslot.Integrations.Stripe.Disputes
  alias Tymeslot.Integrations.Stripe.Pagination
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema

  @page_size 100

  @type outcome ::
          {:recorded | :would_record | :unchanged, BookingPaymentSchema.t(), pos_integer()}
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
  Reads every candidate's disputes from Stripe and records what lost ones
  took. Options:

    * `:dry_run` (default `true`): read from Stripe, write nothing, and
      count what would be recorded as `lost`;
    * `:pause_ms` (default 100): the pause between Stripe calls;
    * `:limit` (default `nil`, every candidate): how many candidates to read;
    * `:on_outcome`: called with each payment's `t:outcome/0` other than
      "no lost dispute", for reporting.

  `lost` counts payments with a lost dispute, `updated` those written,
  `clamped` those whose loss was cut to the refunded total, `unchanged`
  those another process recorded first. A failed Stripe call goes into
  `errors` with the payment id, and the run carries on.
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
  What the lost disputes in `disputes` took from `payment`: `:none`,
  `{:lost, cents}`, or `{:clamped, cents}` when their sum exceeds the
  refunded total and is cut to it, so the share stays within the whole
  (the `disputed_lost_within_refunded` check).
  """
  @spec lost_cents([map()], %{refunded_amount_cents: non_neg_integer()}) ::
          :none | {:lost | :clamped, pos_integer()}
  def lost_cents(disputes, %{refunded_amount_cents: refunded}) when is_list(disputes) do
    sum =
      disputes
      |> Enum.filter(&match?(%{"status" => "lost"}, &1))
      |> Enum.map(&Map.fetch!(&1, "amount"))
      |> Enum.sum()

    cond do
      sum <= 0 or refunded <= 0 -> :none
      sum > refunded -> {:clamped, refunded}
      true -> {:lost, sum}
    end
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
    case Pagination.collect(&Disputes.list/2, %{charge: payment.stripe_charge_id},
           connect_account: payment.stripe_account_id
         ) do
      {:ok, disputes} -> record(payment, lost_cents(disputes, payment), opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp record(_payment, :none, _opts), do: :none

  defp record(payment, {_kind, cents} = loss, opts) do
    if opts[:dry_run] do
      {:would_record, loss}
    else
      {:ok, written} = BookingPaymentQueries.record_dispute_loss(payment.id, cents)
      {written, loss}
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

      {written, {kind, cents}} ->
        on_outcome.({written, payment, cents})

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
