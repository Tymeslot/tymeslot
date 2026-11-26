defmodule Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted do
  @moduledoc """
  Handler for the Stripe `checkout.session.completed` Connect event.

  Marks the matching `booking_payment` as paid, transitions the meeting
  from `awaiting_payment` to `confirmed`, and triggers the same
  side-effect pipeline (calendar push + confirmation emails) that the
  free booking flow uses. The whole state mutation runs inside a single
  transaction, decided from the payment and meeting rows under their row
  locks, so a crash mid-flow rolls back cleanly and two completions of one
  payment cannot both confirm it.

  Idempotent — replaying an event whose id matches the stored
  `last_event_id` is a no-op, as is delivering an event for a meeting
  that is no longer in `awaiting_payment`, with one exception: a meeting
  that expired while its payment was being taken (its payment marked
  `failed`) is confirmed after all if its slot is still free, and the
  payment is recorded as paid and a refund of all of it recorded
  (`Refunds.request_remaining_refund/2`) if the slot has been taken since. Also a
  no-op when the session's `payment_status` is not `"paid"` (an
  asynchronous payment method still settling), matching the gate
  `ReconcileAwaitingPayments.dispatch/2` applies when it replays this
  same event.

  The payment of a paid series is handed to `Webhooks.SeriesCheckoutCompleted`,
  and that of a held group seat to `Webhooks.SeatCheckoutCompleted`, once
  the amount and the paid status have been checked here.

  A host whose account is pending deletion takes no booking: a checkout
  completed for one leaves the meeting expired and its payment refunded in
  full the same way. So is a payment whose meeting no longer exists,
  because its host's account has been deleted since the checkout opened,
  and one whose booking was released before its payment was recorded (the
  host cancelled it while its checkout was open, say): that booking stays
  as it is, and is never reinstated the way an expired one can be.

  The booking is resolved through `PaymentLookup.find_for_session/1`, which
  ignores events from any connected account other than the one the booking
  was charged on, and a session whose `amount_total` or `currency` differs
  from the price snapshotted on the row is ignored too.
  """

  @behaviour Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger

  alias Tymeslot.Availability
  alias Tymeslot.Bookings.Activation
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.HeldMeetings
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.MeetingPayments.Telemetry
  alias Tymeslot.MeetingPayments.Webhooks.LockedPayment
  alias Tymeslot.MeetingPayments.Webhooks.PaymentCompletion
  alias Tymeslot.MeetingPayments.Webhooks.PaymentLookup
  alias Tymeslot.MeetingPayments.Webhooks.SeatCheckoutCompleted
  alias Tymeslot.MeetingPayments.Webhooks.SeriesCheckoutCompleted
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.Payments.Behaviours.WebhookHandler
  alias Tymeslot.Repo

  @event_type "checkout.session.completed"

  @impl WebhookHandler
  @spec handle(map()) :: WebhookHandler.result()
  def handle(event) do
    Telemetry.span_webhook(@event_type, fn -> do_handle(event) end)
  end

  defp do_handle(%{"id" => event_id, "data" => %{"object" => object}} = event) do
    case PaymentLookup.find_for_session(event) do
      nil ->
        Logger.info("checkout.session.completed: no booking_payment matched",
          checkout_session_id: object["id"],
          meeting_id: object["client_reference_id"]
        )

        {:ok, :ok}

      %BookingPaymentSchema{last_event_id: ^event_id} ->
        Logger.info("checkout.session.completed: idempotent replay", event_id: event_id)
        {:ok, :idempotent_replay}

      payment ->
        handle_payment(payment, event_id, object)
    end
  end

  defp do_handle(_other), do: {{:error, :permanent, :invalid_event}, :error}

  # Mirrors the `%{"payment_status" => "paid"} = session` gate
  # `ReconcileAwaitingPayments.dispatch/2` applies before replaying this same
  # event. Without it, an asynchronous payment method (e.g. SEPA Direct
  # Debit) fires this event with `payment_status: "unpaid"` and this handler
  # would confirm the meeting before the money has actually settled.
  defp handle_payment(payment, event_id, %{"payment_status" => "paid"} = object) do
    if charged_as_booked?(payment, object) do
      classify(complete_payment(payment, event_id, object))
    else
      Logger.error("checkout.session.completed: amount or currency does not match the booking",
        payment_id: payment.id,
        checkout_session_id: object["id"],
        amount_total: object["amount_total"],
        currency: object["currency"]
      )

      {:ok, :skipped}
    end
  end

  defp handle_payment(payment, _event_id, object) do
    Logger.info("checkout.session.completed: payment not yet paid, skipping",
      payment_id: payment.id,
      payment_status: object["payment_status"]
    )

    {:ok, :skipped}
  end

  # The session must have charged exactly the price snapshotted on the row
  # when checkout was created; anything else is not this booking's payment.
  defp charged_as_booked?(%{amount_cents: amount, currency: currency}, %{
         "amount_total" => amount,
         "currency" => session_currency
       })
       when is_binary(currency) and is_binary(session_currency),
       do: String.downcase(session_currency) == String.downcase(currency)

  defp charged_as_booked?(_payment, _object), do: false

  defp classify(:ok), do: {:ok, :ok}
  defp classify({:error, reason}), do: {{:error, :retry_later, reason}, :error}

  # A seat payment whose hold is gone (deleted on erasure, or 30 days after
  # it settled) has no seat left to book: one still awaiting its money is
  # refunded in full, as a payment whose meeting is gone is. It never
  # confirms the group meeting it was held on, which other seats share.
  defp complete_payment(
         %BookingPaymentSchema{seat_payment: true, seat_hold_id: nil} = payment,
         event_id,
         object
       ),
       do: refund_holdless_seat(payment, event_id, object)

  # A series' one payment confirms every session of it.
  defp complete_payment(%BookingPaymentSchema{series_id: series_id} = payment, event_id, object)
       when is_binary(series_id),
       do: SeriesCheckoutCompleted.run(payment, event_id, object)

  # A held group seat's payment books the seat (or refunds it).
  defp complete_payment(%BookingPaymentSchema{seat_hold_id: hold_id} = payment, event_id, object)
       when is_binary(hold_id),
       do: SeatCheckoutCompleted.run(payment, event_id, object)

  defp complete_payment(payment, event_id, object), do: run(payment, event_id, object)

  defp refund_holdless_seat(payment, event_id, object) do
    case LockedPayment.run(payment, event_id, &refund_orphaned(&1, event_id, object)) do
      {:ok, {:refused, :meeting_missing, paid, nil}} ->
        after_refusal(:meeting_missing, paid, nil, event_id, object)

      {:ok, outcome} when outcome in [:no_op, :idempotent_replay] ->
        :ok

      {:error, reason} ->
        Logger.error("checkout.session.completed handler failed",
          event_id: event_id,
          reason: LogFormat.reason(reason)
        )

        {:error, reason}
    end
  end

  # Activation (the video room, the emails) runs only for the transaction
  # that moved the rows itself. A second completion of the same payment, the
  # reconciler replaying it under its own event id say, waits on the row
  # lock, then finds the meeting no longer awaiting payment and does nothing.
  defp run(payment, event_id, object) do
    case complete(payment, event_id, object) do
      {:ok, {:advanced, paid, meeting, pending}} ->
        after_payment(paid, meeting, pending, object)

      {:ok, {:recovered, paid, meeting, pending}} ->
        Logger.warning(
          "checkout.session.completed: recovery transition — completed event arrived after expiry",
          meeting_id: meeting.id,
          payment_id: paid.id,
          event_id: event_id
        )

        after_payment(paid, meeting, pending, object)

      {:ok, {:refund_scheduled, paid, meeting}} ->
        after_late_refund_scheduled(paid, meeting, event_id)

      {:ok, {:refused, reason, paid, meeting}} ->
        after_refusal(reason, paid, meeting, event_id, object)

      {:ok, outcome} when outcome in [:no_op, :idempotent_replay] ->
        :ok

      {:error, reason} ->
        Logger.error("checkout.session.completed handler failed",
          event_id: event_id,
          reason: LogFormat.reason(reason)
        )

        {:error, reason}
    end
  end

  # Backfill stripe_charge_id outside the transaction — this requires a
  # Stripe API call (expanding payment_intent.latest_charge) which must
  # not be made inside a DB transaction.  Charge handlers (refund/dispute)
  # all look up the row via stripe_charge_id so this field is required for
  # them to work.  A failure here does not roll back the payment
  # transition: the read is handed to `Workers.BackfillCharge`.
  defp after_payment(paid, meeting, pending, object) do
    PaymentCompletion.backfill_charge_id(paid, object)
    PaymentCompletion.emit_payment_succeeded(paid, meeting)
    HeldMeetings.broadcast(meeting.id, :paid)
    Availability.changed(meeting.organizer_user_id)
    Activation.after_commit(pending)
  end

  defp after_late_refund_scheduled(paid, meeting, event_id) do
    Logger.warning(
      "checkout.session.completed: completed after expiry with the slot taken, refund scheduled",
      meeting_id: meeting.id,
      payment_id: paid.id,
      event_id: event_id
    )

    HeldMeetings.broadcast(meeting.id, :expired)
    :ok
  end

  defp after_refusal(:meeting_missing, paid, nil, event_id, object) do
    Logger.warning(
      "checkout.session.completed: booking no longer exists, refund scheduled",
      payment_id: paid.id,
      event_id: event_id
    )

    PaymentCompletion.backfill_charge_id(paid, object)
  end

  # `reason` is `:host_pending_deletion`, or `:released` for a booking
  # released before its payment was recorded. The waiting attendee is told
  # the booking will not go ahead.
  defp after_refusal(reason, paid, meeting, event_id, object) do
    Logger.warning(
      "checkout.session.completed: booking refused and refund scheduled",
      reason: reason,
      meeting_id: meeting.id,
      payment_id: paid.id,
      event_id: event_id
    )

    PaymentCompletion.backfill_charge_id(paid, object)
    HeldMeetings.announce_expired(meeting)
  end

  # A completion arriving after its booking expired (`:recovered` below)
  # brings the booking back only if nobody has taken the slot since the
  # expiry released it. The first attempt takes no schedule lock and backs
  # out on finding that case; the second runs under the organiser's schedule
  # lock with the slot counted free (`Scheduling.reinstate_with_conflict_check/2`),
  # and a slot found taken refunds the payment instead. So does a booking made
  # through an invitation that has been booked again since the expiry: the
  # invitation index refuses the second live booking it would make.
  defp complete(payment, event_id, object) do
    case LockedPayment.run(
           payment,
           event_id,
           &run_in_transaction(&1, event_id, object, :unchecked)
         ) do
      {:error, :slot_unchecked} -> recover(payment, event_id, object)
      result -> result
    end
  end

  defp recover(payment, event_id, object) do
    with {:ok, meeting} <- fetch_meeting(payment.meeting_id) do
      write_fn = fn ->
        case LockedPayment.run(
               payment,
               event_id,
               &run_in_transaction(&1, event_id, object, :free)
             ) do
          {:ok, value} -> value
          {:error, reason} -> Repo.rollback(reason)
        end
      end

      meeting
      |> Scheduling.reinstate_with_conflict_check(write_fn)
      |> PaymentCompletion.refund_if_slot_lost(fn ->
        refund_late_payment(payment, event_id, object)
      end)
    end
  end

  # Runs under the payment's row lock (`LockedPayment`); the meeting row is
  # locked next, so the transition is decided from both rows as committed.
  # `slot` says whether the organiser's schedule lock is held with the
  # meeting's slot counted free, which a recovery needs.
  defp run_in_transaction(%{meeting_id: nil} = payment, event_id, object, _slot),
    do: refund_orphaned(payment, event_id, object)

  defp run_in_transaction(payment, event_id, object, slot) do
    with {:ok, meeting} <- lock_meeting(payment.meeting_id),
         {:proceed, transition} <- check_transition(meeting, payment),
         :ok <- PaymentCompletion.host_accepting(meeting),
         :ok <- slot_checked(transition, slot),
         {:ok, paid} <- PaymentCompletion.mark_paid(payment, event_id, object),
         {:ok, confirmed} <-
           MeetingQueries.update_meeting_status(
             meeting,
             PaymentCompletion.post_payment_status(meeting)
           ),
         {:ok, _job_status} <- PaymentCompletion.schedule_calendar_creation(confirmed),
         {:ok, pending} <- activate(confirmed) do
      {:ok, {transition, paid, confirmed, pending}}
    else
      :no_op -> {:ok, :no_op}
      {:refuse, reason, meeting} -> refuse(payment, meeting, event_id, object, reason)
      {:error, _reason} = error -> error
    end
  end

  # The booking is not confirmed: the meeting is put `expired`, or left as it
  # is when released already (cancelled, or expired), and the payment, which
  # truly was taken, is recorded paid with a refund of all of it, made by its
  # job, which emails the attendee once Stripe has accepted it. No Stripe
  # call is made here; see `refund_late_payment/3`.
  defp refuse(payment, meeting, event_id, object, reason) do
    with {:ok, paid} <- PaymentCompletion.mark_paid(payment, event_id, object),
         {:ok, released} <- release(meeting),
         {:ok, _refund} <- Refunds.request_remaining_refund(paid, :late_payment) do
      {:ok, {:refused, reason, paid, released}}
    end
  end

  # The meeting is gone: its host's account was deleted (the meetings go
  # with it and the payment row keeps no meeting), so there is no booking to
  # confirm. A payment still awaiting its money is recorded paid and refunded
  # in full like a refused one; one already recorded is a replay of this.
  defp refund_orphaned(%{status: status} = payment, event_id, object)
       when status in [:pending, :failed] do
    with {:ok, paid} <- PaymentCompletion.mark_paid(payment, event_id, object),
         {:ok, _refund} <- Refunds.request_remaining_refund(paid, :late_payment) do
      {:ok, {:refused, :meeting_missing, paid, nil}}
    end
  end

  defp refund_orphaned(_payment, _event_id, _object), do: {:ok, :no_op}

  defp release(%{status: status} = meeting) do
    if MeetingState.released_status?(status),
      do: {:ok, meeting},
      else: MeetingQueries.update_meeting_status(meeting, %{status: :expired})
  end

  defp slot_checked(:recovered, :unchecked), do: {:error, :slot_unchecked}
  defp slot_checked(_transition, _slot), do: :ok

  # The attendee paid for a booking whose slot someone else has since been
  # given, so the booking stays expired and the whole payment goes back.
  # The payment is marked paid, as it truly was, and the refund recorded in
  # this same transaction, to be made by its job: a Stripe call made here
  # would hold the row locks for as long as Stripe takes, and a lasting
  # Stripe failure would roll back every delivery of this event while the
  # money sat unseen. Once this commits, the booking is on the host's
  # outstanding-refunds list until the refund goes through.
  #
  # The refund needs the charge id, which is backfilled beforehand, outside
  # the transaction, since that is a Stripe call. A backfill that fails does
  # not hold the payment back: it is committed paid with its refund all the
  # same, and each attempt at the refund backfills the charge id first
  # (`RefundExecutor`). Left uncommitted instead, the payment would stay
  # `failed`, off the host's outstanding refunds, once Stripe stopped
  # redelivering this event.
  defp refund_late_payment(payment, event_id, object) do
    PaymentCompletion.backfill_charge_id(payment, object)

    LockedPayment.run(payment, event_id, fn locked ->
      with {:ok, meeting} <- lock_meeting(locked.meeting_id),
           {:proceed, :recovered} <- check_transition(meeting, locked),
           {:ok, paid} <- PaymentCompletion.mark_paid(locked, event_id, object),
           {:ok, _refund} <- Refunds.request_remaining_refund(paid, :late_payment) do
        {:ok, {:refund_scheduled, paid, meeting}}
      else
        {:error, _reason} = error -> error
        _no_longer_recoverable -> {:ok, :no_op}
      end
    end)
  end

  defp fetch_meeting(nil), do: {:error, :meeting_missing}
  defp fetch_meeting(meeting_id), do: MeetingQueries.get_meeting(meeting_id)

  defp lock_meeting(nil), do: {:error, :meeting_missing}
  defp lock_meeting(meeting_id), do: MeetingQueries.get_meeting_for_update(meeting_id)

  # Determine the transition type based on meeting and payment state.
  # Returns `{:proceed, type}` to continue the with-chain, or `:no_op` to
  # short-circuit (falls to the else clause).
  #
  # Transitions:
  #   :advanced  — normal happy path (meeting awaiting_payment)
  #   :recovered — completed event arrived after the booking expired and its
  #                payment was failed (the expired webhook, or a disconnect,
  #                ran first); re-confirmed only if the slot is still free,
  #                refunded otherwise (see `complete/3`)
  #   :refuse    — any other released meeting (one cancelled while its checkout
  #                was open) whose payment is not recorded yet (`paid_at` nil,
  #                whether still pending, failed or already disputed); the
  #                payment is refunded and the meeting left as it is, never
  #                reinstated, so this is decided before any slot check
  #   :no_op     — meeting already in a non-recoverable terminal state, or a
  #                payment recorded already (a replay); skip
  defp check_transition(%{status: :awaiting_payment}, _payment), do: {:proceed, :advanced}
  defp check_transition(%{status: :expired}, %{status: :failed}), do: {:proceed, :recovered}

  defp check_transition(%{status: status} = meeting, %{paid_at: nil}) do
    if MeetingState.released_status?(status), do: {:refuse, :released, meeting}, else: :no_op
  end

  defp check_transition(_meeting, _payment), do: :no_op

  # The public booking page derives occupancy from the organiser's connected
  # calendars alone, so a booking only stops being offered once it has been
  # written there as an event. The free path schedules that write inside the
  # booking transaction; a paid booking is not confirmed until this webhook
  # lands, so its write is scheduled inside `run_in_transaction/4`
  # (`schedule_calendar_creation/1`), atomically with the payment/meeting
  # transition.
  #
  # The video room, the emails and the reminders are `Bookings.Activation`'s,
  # shared with the free path so the two cannot drift, and they commit with
  # the transition too: an email that cannot be queued rolls the payment and
  # the meeting back to where they were, the handler answers `:retry_later`,
  # and Stripe's redelivery confirms the booking whole. Activation also
  # refuses to confirm a booking that landed in the approval gate: a paid
  # request is not a booking anyone has agreed to, so it takes the request
  # fan-out instead, and `Meetings.Approval` confirms it once the host says
  # yes. Only the integration fan-out waits for the commit (`after_payment/4`).
  defp activate(confirmed),
    do: Activation.activate_in_transaction(confirmed, with_video_room: true)
end
