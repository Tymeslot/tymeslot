defmodule Tymeslot.MeetingPayments.Webhooks.ChargeDisputeClosed do
  @moduledoc """
  Handler for the Stripe `charge.dispute.closed` Connect event.

  Reconciles status after a dispute is decided:

    * `won` → revert to `paid` (or `partially_refunded` if any prior
      refund was on the row before the dispute opened). A payment whose
      booking expired (it completed after its slot was taken, say) still
      owes the attendee: its automatic refund was given up while the
      dispute held the money, so it is scheduled again here, in the same
      transaction (`RefundLatePayment.new_after_dispute/1`).
    * `lost` → set `refunded_amount_cents` to the disputed amount and
      derive `refunded` / `partially_refunded` accordingly. Stripe debits
      the host's balance for the disputed amount when a dispute is lost,
      so the row should reflect the funds being gone from the host's
      perspective.
    * `warning_closed` (an inquiry that never became a chargeback) and
      `prevented` (one stopped before it did) are final and withdraw no
      funds, so they resolve the same way as `won`.
    * any other status (`warning_under_review`, `needs_response`, …) is a
      live dispute, which a replayed or mis-routed event must not clear:
      the booking stays `disputed`.

  Whichever way a final dispute goes, a payment whose booking expired is
  refunded whatever is left of it with the host: all of it after a won
  dispute, the part a lost one did not take back after a partial loss
  (`partially_refunded`). The attendee paid for a booking that never
  happened, so nothing of it is the host's to keep.

  A final outcome also records the dispute as closed on the payment
  (`stripe_dispute_id`, `dispute_closed_at`), whether or not it changes the
  status, so a `charge.dispute.created` for the same dispute that Stripe
  delivers late is recognised and ignored (`ChargeDisputeCreated`). A
  `closed` that arrives before its `created` is applied as usual: the guard
  keys on the dispute, never on the row being `disputed`.

  The same identity guards this handler: a `closed` for one dispute while
  the payment records a different one as open (an inquiry's close
  delivered after the chargeback it escalated into was created) is
  ignored, so it cannot clear the live dispute or schedule a refund
  while that dispute still holds the money.

  Idempotent on `last_event_id`.
  """

  @behaviour Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.Telemetry
  alias Tymeslot.MeetingPayments.Webhooks.DisputeOutcome
  alias Tymeslot.MeetingPayments.Webhooks.LockedPayment
  alias Tymeslot.MeetingPayments.Webhooks.PaymentLookup
  alias Tymeslot.MeetingPayments.Workers.RefundLatePayment
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Payments.Behaviours.WebhookHandler

  @event_type "charge.dispute.closed"

  @impl WebhookHandler
  @spec handle(map()) :: WebhookHandler.result()
  def handle(event) do
    Telemetry.span_webhook(@event_type, fn -> do_handle(event) end)
  end

  defp do_handle(%{"id" => event_id, "data" => %{"object" => object}} = event) do
    case PaymentLookup.find_for_charge(event, object["charge"]) do
      nil ->
        Logger.info("charge.dispute.closed: no booking_payment matched",
          charge_id: object["charge"]
        )

        {:ok, :ok}

      %BookingPaymentSchema{last_event_id: ^event_id} ->
        {:ok, :idempotent_replay}

      payment ->
        outcome = DisputeOutcome.from_status(object["status"])
        classify(apply_outcome(payment, event_id, outcome, object))
    end
  end

  defp do_handle(_other), do: {{:error, :permanent, :invalid_event}, :error}

  defp classify(:ok), do: {:ok, :ok}
  defp classify({:error, reason}), do: {{:error, :retry_later, reason}, :error}

  defp apply_outcome(_payment, _event_id, nil, _amount), do: :ok

  # Decided from the locked row (`LockedPayment`): a `charge.refunded`
  # committed since the row was resolved must be counted, not written over.
  defp apply_outcome(payment, event_id, outcome, object) do
    dispute_id = object["id"]

    result =
      LockedPayment.run(payment, event_id, fn locked ->
        if another_dispute_open?(locked, dispute_id) do
          {:ok, :another_dispute_open}
        else
          close_dispute(locked, event_id, outcome, object)
        end
      end)

    case result do
      {:ok, :idempotent_replay} ->
        :ok

      {:ok, :another_dispute_open} ->
        Logger.info("charge.dispute.closed: another dispute is open on the payment, ignored",
          booking_payment_id: payment.id,
          dispute_id: dispute_id
        )

        :ok

      {:ok, {old_status, new_status}} ->
        Telemetry.emit_status_changed(old_status, new_status, :webhook_dispute_closed)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A row that records a different dispute as still open belongs to that
  # dispute: a late or retried close for an earlier one (an inquiry closed
  # after the chargeback it escalated into was opened) must not clear it.
  # A row with no recorded dispute, open since before disputes were
  # tracked, is closed by whichever dispute closes.
  defp another_dispute_open?(
         %BookingPaymentSchema{stripe_dispute_id: recorded, dispute_closed_at: nil},
         dispute_id
       )
       when is_binary(recorded),
       do: recorded != dispute_id

  defp another_dispute_open?(_locked, _dispute_id), do: false

  defp close_dispute(locked, event_id, outcome, object) do
    attrs =
      locked
      |> outcome_attrs(outcome, object["amount"] || 0)
      |> Map.merge(%{
        last_event_id: event_id,
        stripe_dispute_id: object["id"],
        dispute_closed_at: DateTime.utc_now(:second)
      })

    with {:ok, updated} <- BookingPaymentQueries.update(locked, attrs),
         {:ok, _job} <- maybe_schedule_refund(updated) do
      {:ok, {locked.status, updated.status}}
    end
  end

  # Money back with the host for a booking that never happened is owed to
  # the attendee, as it was before the dispute opened: after a won dispute,
  # and after a partly lost one, for the part the dispute did not take.
  defp maybe_schedule_refund(%{status: status, meeting_id: meeting_id} = payment)
       when is_binary(meeting_id) do
    with true <- status in BookingPaymentSchema.refundable_statuses(),
         {:ok, %{status: :expired}} <- MeetingQueries.get_meeting(meeting_id) do
      Oban.insert(RefundLatePayment.new_after_dispute(payment.id))
    else
      _not_owed -> {:ok, :none}
    end
  end

  defp maybe_schedule_refund(_payment), do: {:ok, :none}

  defp outcome_attrs(payment, :won, _disputed_amount),
    do: %{status: derive_status_from_refund(payment, payment.refunded_amount_cents)}

  defp outcome_attrs(payment, :lost, disputed_amount) do
    new_total = max(payment.refunded_amount_cents, disputed_amount)
    %{status: derive_status_from_refund(payment, new_total), refunded_amount_cents: new_total}
  end

  defp derive_status_from_refund(%{amount_cents: amount_cents}, refunded) do
    cond do
      refunded >= amount_cents -> :refunded
      refunded > 0 -> :partially_refunded
      true -> :paid
    end
  end
end
