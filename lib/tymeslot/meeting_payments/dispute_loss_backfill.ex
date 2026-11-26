defmodule Tymeslot.MeetingPayments.DisputeLossBackfill do
  @moduledoc """
  Rebuilds, from what Stripe records, the refund figures of payments whose
  dispute was lost before the figures kept the refunds made apart from the
  loss.

  Two kinds of row need it. A dispute lost before `disputed_lost_cents`
  existed left the loss at 0 and a refunded total the older handlers wrote
  as the larger of the refunds and the disputed amount, not their sum: a
  payment refunded 4_000 and then disputed and lost over 3_000 holds
  4_000, not 7_000, and the host may refund more than is left. A dispute
  lost before `stripe_refunded_cents` existed has its loss recorded, but
  the refunds made were filled in as the total less the loss, which the
  cap at the amount paid can hide: a payment refunded in full and then
  lost in full shows no refunds at all.

  The loss is on no row (Connect webhook payloads are not kept), but Stripe
  lists a charge's disputes, and the charge's `amount_refunded` counts its
  refunds alone. From the two each row gets what a loss recorded today
  gives it: the refunds made, the dispute's share
  (`RefundedTotal.with_dispute_lost/2`), a refunded total of the two within
  the amount paid, and the status that total implies. The total is never
  lowered.

  An operator runs this once per deployment that takes payments, through
  `Tymeslot.Release.backfill_dispute_losses/1`; it is never run at boot,
  since it calls the deployment's own Stripe account.

  The candidates are payments with a charge and either of two shapes. The
  first is something refunded, no loss recorded, and status `refunded` or
  `partially_refunded`: every release that handled disputes left a lost
  one in one of those two statuses. Only a payment created before the
  deployment ran the `disputed_lost_cents` migration can hold a loss
  recorded that way, and of those, one created after it ran the dispute
  tracking migration carries the closed dispute's id (`stripe_dispute_id`):
  the release that added the column stamps it on every dispute that
  closes. A payment created earlier may have lost a dispute that left no
  marker, so it is read whatever it carries. A `disputed` row is out of
  scope: a refund on it is refused while it is `disputed`
  (`:under_dispute`), so it cannot be refunded too much. The second is a
  recorded loss whose refunds and loss add up to exactly the amount paid,
  on a payment created before the deployment ran the `stripe_refunded_cents`
  migration: the shape a hidden refund was filled in as. A payment whose
  refunds and loss truly come to the amount paid has it too, and is left
  as it is. When each migration ran is read from the deployment's own
  `schema_migrations` (`BookingPaymentQueries.dispute_loss_candidates/2`),
  since a self-hosted deployment upgrades when it chooses.

  Each candidate costs one Stripe call to list its disputes, and one more
  to read the charge when one was lost; a payment with no lost dispute, or
  whose figures already match Stripe's, is left as it is. The write is
  guarded on the figures and status read, so a second run, or a webhook
  changing the row meanwhile, writes nothing. A second run reads again the
  payments of the second shape. No transaction or row lock is held across
  a Stripe call: candidates are read a page at a time by id.
  """

  alias Tymeslot.Integrations.Stripe.Charges
  alias Tymeslot.Integrations.Stripe.Disputes
  alias Tymeslot.Integrations.Stripe.Pagination
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.RefundedTotal

  @page_size 100

  @type correction :: RefundedTotal.figures()

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

  `lost` counts payments with a lost dispute whose figures Stripe's
  correct, `updated` those written, `clamped` those whose loss was cut to
  the amount paid, `unchanged` those another process changed first. A failed Stripe call goes into `errors`
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
  What the lost disputes among `disputes` (as Stripe lists them for a
  charge) took back, in cents; 0 when none was lost.
  """
  @spec lost_total([map()]) :: non_neg_integer()
  def lost_total(disputes) when is_list(disputes) do
    disputes
    |> Enum.filter(&match?(%{"status" => "lost"}, &1))
    |> Enum.reduce(0, &add_amount/2)
  end

  defp add_amount(%{"amount" => amount}, total) when is_integer(amount) and amount >= 0,
    do: total + amount

  @doc """
  What `payment` should record once its charge's disputes took back
  `lost_cents` and Stripe returns its `charge`: `{:lost, correction}`, or
  `{:clamped, correction}` when `lost_cents` exceeds the amount paid and
  the share is cut to it.

  The refunds made are the charge's, unless fewer would lower the total
  `payment` holds; the refunded total is the refunds plus the loss, within
  the amount paid (`RefundedTotal.with_dispute_lost/2`). The share is
  within that total either way, as the `disputed_lost_within_refunded`
  check requires.
  """
  @spec correction(BookingPaymentSchema.t(), pos_integer(), map()) ::
          {:lost | :clamped, correction()}
  def correction(payment, lost_cents, %{"amount_refunded" => stripe_refunded})
      when is_integer(lost_cents) and lost_cents > 0 and is_integer(stripe_refunded) do
    %{disputed_lost_cents: lost} = RefundedTotal.with_dispute_lost(payment, lost_cents)
    refunds = max(stripe_refunded, payment.refunded_amount_cents - lost)
    kind = if lost < lost_cents, do: :clamped, else: :lost

    {kind, RefundedTotal.figures(payment, refunds, lost)}
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
      case lost_total(disputes) do
        0 ->
          :none

        lost_cents ->
          with {:ok, charge} <- Charges.retrieve(payment.stripe_charge_id, stripe_opts) do
            record(payment, correction(payment, lost_cents, charge), opts)
          end
      end
    end
  end

  defp record(payment, {_kind, correction} = result, opts) do
    cond do
      Map.take(payment, Map.keys(correction)) == correction ->
        :none

      opts[:dry_run] ->
        {:would_record, result}

      true ->
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
