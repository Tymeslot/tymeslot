defmodule Tymeslot.MeetingPayments.Webhooks.ChargeDisputeClosed do
  @moduledoc """
  Handler for the Stripe `charge.dispute.closed` Connect event.

  Reconciles status after a dispute is decided:

    * `won` → revert to `paid` (or `partially_refunded` if any prior
      refund was on the row before the dispute opened). A payment whose
      booking never happened still owes the attendee: its automatic
      refund was given up while the dispute held the money, so a refund
      of what is left is recorded here, in the same transaction
      (`Refunds.request_remaining_refund/2`).
    * `lost` → record the disputed amount as `disputed_lost_cents`, add
      it to `refunded_amount_cents` (`RefundedTotal`) and derive
      `refunded` / `partially_refunded` accordingly. Stripe debits
      the host's balance for the disputed amount when a dispute is lost,
      so the row should reflect the funds being gone from the host's
      perspective.
    * `warning_closed` (an inquiry that never became a chargeback) and
      `prevented` (one stopped before it did) are final and withdraw no
      funds, so they resolve the same way as `won`.
    * any other status (`warning_under_review`, `needs_response`, …) is a
      live dispute, which a replayed or mis-routed event must not clear:
      the booking stays `disputed`.

  Whichever way a final dispute goes, a payment whose booking never
  happened is refunded whatever is left of it with the host: all of it
  after a won dispute, the part a lost one did not take back after a
  partial loss (`partially_refunded`). That is a booking that expired
  waiting on its payment, one whose late payment its completion refused,
  and a request released through the approval gate without ever having
  been a meeting: the attendee is owed all of it, so nothing is the host's
  to keep. A booking that went ahead keeps whatever refund its host chose.

  A paid seat of a group session never happened when its seat hold never
  became a booked seat (refused for a full slot, say), whatever became of
  the meeting it was held on, which other seats may keep going ahead. A
  booked seat is owed the rest too once its host refunded it on cancelling
  the session, including a refund the dispute held back then.

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
  alias Tymeslot.MeetingPayments.HeldMeetings
  alias Tymeslot.MeetingPayments.RefundedTotal
  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.MeetingPayments.Telemetry
  alias Tymeslot.MeetingPayments.Webhooks.DisputeOutcome
  alias Tymeslot.MeetingPayments.Webhooks.LockedPayment
  alias Tymeslot.MeetingPayments.Webhooks.PaymentLookup
  alias Tymeslot.Meetings.ApprovalRelease
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Payments.Behaviours.WebhookHandler

  @event_type "charge.dispute.closed"

  @impl WebhookHandler
  @spec handle(map()) :: WebhookHandler.result()
  def handle(event) do
    Telemetry.span_webhook(@event_type, fn -> do_handle(event) end)
  end

  defp do_handle(%{"id" => event_id, "data" => %{"object" => object}} = event) do
    case PaymentLookup.find_for_charge(event, object["charge"]) do
      {:error, reason} ->
        {{:error, :retry_later, reason}, :error}

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
         {:ok, _refund} <- maybe_request_refund(updated) do
      {:ok, {locked.status, updated.status}}
    end
  end

  # Money back with the host for a booking that never happened is owed to
  # the attendee, as it was before the dispute opened: after a won dispute,
  # and after a partly lost one, for the part the dispute did not take. A
  # series never happened when none of its sessions did
  # (`never_happened?/2`). A refund still pending holds its share, so a
  # second close of the dispute records nothing more.
  #
  # A paid seat never happened when its hold never became a participant,
  # whatever became of the meeting it was held on. A booked seat is owed
  # what came back once its host has refunded it on cancelling its session:
  # a refund the dispute held back is recorded then (`Meetings.Cancellation`),
  # and one made before the dispute opened leaves whatever it did not cover.
  #
  # A seat is told apart by its immutable `seat_payment` marker rather than
  # by its hold, which is deleted 30 days after it settles (or on erasure):
  # a refused seat whose hold is gone is still a seat that never happened.
  defp maybe_request_refund(%BookingPaymentSchema{seat_payment: true} = payment) do
    if payment.status in BookingPaymentSchema.refundable_statuses() and
         (is_nil(payment.participant_id) or
            RefundQueries.recorded_from?(payment.id, :cancellation)),
       do: Refunds.request_remaining_refund(payment, :late_payment),
       else: {:ok, :none}
  end

  defp maybe_request_refund(payment) do
    with true <- payment.status in BookingPaymentSchema.refundable_statuses(),
         [_first | _rest] = meetings <- HeldMeetings.meetings_for(payment),
         refused? = RefundQueries.recorded_from?(payment.id, :late_payment),
         true <- Enum.all?(meetings, &never_happened?(&1, refused?)) do
      Refunds.request_remaining_refund(payment, :late_payment)
    else
      _not_owed -> {:ok, :none}
    end
  end

  # A lapsed reschedule request was a confirmed, paid booking, and keeps
  # `reschedule_requested_at` as the record of why it expired; its refund is
  # left to the host (`Bookings.RescheduleRequestExpiry`). A request released
  # through the approval gate is refunded in full unless it had been a
  # meeting before a reschedule sent it back through the gate, the rule its
  # release applies (`ApprovalRelease.refunds_on_release?/1`). Any other
  # expiry released a booking still waiting on its payment. Any other
  # cancellation counts only when the payment completed after it, which
  # `refused?` says: the completion then refused the booking and recorded a
  # `:late_payment` refund (`CheckoutSessionCompleted`), failed already when
  # the dispute came first (`Refunds.request_remaining_refund/2`), whichever
  # second each landed in. One paid for first went ahead, and its host chose
  # its refund when cancelling it, which a dispute does not overturn.
  defp never_happened?(meeting, refused?) do
    cond do
      not MeetingState.released_status?(meeting.status) -> false
      MeetingState.reschedule_request_lapsed?(meeting) -> false
      ApprovalRelease.released_request?(meeting) -> ApprovalRelease.refunds_on_release?(meeting)
      meeting.status == :expired -> true
      true -> refused?
    end
  end

  defp outcome_attrs(payment, :won, _disputed_amount),
    do: %{status: derive_status_from_refund(payment, payment.refunded_amount_cents)}

  defp outcome_attrs(payment, :lost, disputed_amount) do
    figures = RefundedTotal.with_dispute_lost(payment, disputed_amount)
    %{figures | status: derive_status_from_refund(payment, figures.refunded_amount_cents)}
  end

  defp derive_status_from_refund(%{amount_cents: amount_cents}, refunded) do
    cond do
      refunded >= amount_cents -> :refunded
      refunded > 0 -> :partially_refunded
      true -> :paid
    end
  end
end
