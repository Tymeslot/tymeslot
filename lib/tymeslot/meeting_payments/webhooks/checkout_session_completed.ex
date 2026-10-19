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
  payment is recorded as paid and refunded in full by a job
  (`Workers.RefundLatePayment`) if the slot has been taken since. Also a
  no-op when the session's `payment_status` is not `"paid"` (an
  asynchronous payment method still settling), matching the gate
  `ReconcileAwaitingPayments.dispatch/2` applies when it replays this
  same event.

  A host whose account is pending deletion takes no booking: a checkout
  completed for one leaves the meeting expired and its payment refunded in
  full by the same job. So is a payment whose meeting no longer exists,
  because its host's account has been deleted since the checkout opened.

  The booking is resolved through `PaymentLookup.find_for_session/1`, which
  ignores events from any connected account other than the one the booking
  was charged on, and a session whose `amount_total` or `currency` differs
  from the price snapshotted on the row is ignored too.
  """

  @behaviour Tymeslot.Payments.Behaviours.WebhookHandler

  require Logger

  alias Tymeslot.Auth
  alias Tymeslot.Availability
  alias Tymeslot.Bookings.Activation
  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.ChargeBackfill
  alias Tymeslot.MeetingPayments.HeldMeetings
  alias Tymeslot.MeetingPayments.Telemetry
  alias Tymeslot.MeetingPayments.Webhooks.LockedPayment
  alias Tymeslot.MeetingPayments.Webhooks.PaymentLookup
  alias Tymeslot.MeetingPayments.Workers.RefundLatePayment
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingQueries
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
      classify(run(payment, event_id, object))
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

      {:ok, {:refused, paid, meeting}} ->
        after_refusal(paid, meeting, event_id, object)

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
  # them to work.  A failure here is logged but does not roll back the
  # payment transition; the reconciler can retry if needed.
  defp after_payment(paid, meeting, pending, object) do
    backfill_charge_id(paid, object)
    emit_payment_succeeded(paid, meeting)
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

  defp after_refusal(paid, nil, event_id, object) do
    Logger.warning(
      "checkout.session.completed: booking no longer exists, refund scheduled",
      payment_id: paid.id,
      event_id: event_id
    )

    backfill_charge_id(paid, object)
  end

  defp after_refusal(paid, meeting, event_id, object) do
    Logger.warning(
      "checkout.session.completed: host account pending deletion, booking refused and refund scheduled",
      meeting_id: meeting.id,
      payment_id: paid.id,
      event_id: event_id
    )

    backfill_charge_id(paid, object)
    HeldMeetings.announce_expired(meeting)
  end

  # Best effort: a failure is logged and the payment transition stands. For
  # a late payment being refunded, `RefundLatePayment` backfills again before
  # it refunds.
  defp backfill_charge_id(payment, object) do
    case ChargeBackfill.backfill(payment, object["payment_intent"]) do
      {:ok, _updated} ->
        :ok

      {:error, reason} when reason in [:missing_payment_intent, :charge_not_available] ->
        Logger.warning("checkout.session.completed: charge ID not available on payment intent",
          payment_id: payment.id
        )

      {:error, reason} ->
        Logger.error("checkout.session.completed: failed to backfill stripe_charge_id",
          payment_id: payment.id,
          reason: LogFormat.reason(reason)
        )
    end
  end

  # A completion arriving after its booking expired (`:recovered` below)
  # brings the booking back only if nobody has taken the slot since the
  # expiry released it. The first attempt takes no schedule lock and backs
  # out on finding that case; the second runs under the organiser's schedule
  # lock with the slot counted free (`Scheduling.reinstate_with_conflict_check/2`),
  # and a slot found taken refunds the payment instead.
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

      # A meeting whose organiser is gone has no schedule to come back into.
      case Scheduling.reinstate_with_conflict_check(meeting, write_fn) do
        {:error, reason} when reason in [:time_conflict, :organizer_required] ->
          refund_late_payment(payment, event_id, object)

        result ->
          result
      end
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
         :ok <- host_accepting(meeting),
         :ok <- slot_checked(transition, slot),
         {:ok, paid} <- mark_paid(payment, event_id, object),
         {:ok, confirmed} <-
           MeetingQueries.update_meeting_status(meeting, post_payment_status(meeting)),
         {:ok, _job_status} <- schedule_calendar_creation(confirmed),
         {:ok, pending} <- activate(confirmed) do
      {:ok, {transition, paid, confirmed, pending}}
    else
      :no_op -> {:ok, :no_op}
      {:refuse, :host_pending_deletion, meeting} -> refuse(payment, meeting, event_id, object)
      {:error, _reason} = error -> error
    end
  end

  # A host whose account waits to be deleted takes no booking, even one whose
  # checkout was opened before the deletion was requested.
  defp host_accepting(%{organizer_user_id: user_id} = meeting) when is_integer(user_id) do
    if Auth.deletion_pending?(user_id),
      do: {:refuse, :host_pending_deletion, meeting},
      else: :ok
  end

  defp host_accepting(_meeting), do: :ok

  # The booking is not confirmed: the meeting is left (or put) `expired` and
  # the payment, which truly was taken, is recorded paid and refunded in full
  # by `RefundLatePayment`, inserted in this same transaction, which also
  # emails the attendee once Stripe has accepted the refund. The job
  # backfills the charge id it needs, so no Stripe call is made here.
  defp refuse(payment, meeting, event_id, object) do
    with {:ok, paid} <- mark_paid(payment, event_id, object),
         {:ok, expired} <- expire(meeting),
         {:ok, _job} <- Oban.insert(RefundLatePayment.new_for(paid.id)) do
      {:ok, {:refused, paid, expired}}
    end
  end

  # The meeting is gone: its host's account was deleted (the meetings go
  # with it and the payment row keeps no meeting), so there is no booking to
  # confirm. A payment still awaiting its money is recorded paid and refunded
  # in full like a refused one; one already recorded is a replay of this.
  defp refund_orphaned(%{status: status} = payment, event_id, object)
       when status in ["pending", "failed"] do
    with {:ok, paid} <- mark_paid(payment, event_id, object),
         {:ok, _job} <- Oban.insert(RefundLatePayment.new_for(paid.id)) do
      {:ok, {:refused, paid, nil}}
    end
  end

  defp refund_orphaned(_payment, _event_id, _object), do: {:ok, :no_op}

  defp expire(%{status: "expired"} = meeting), do: {:ok, meeting}
  defp expire(meeting), do: MeetingQueries.update_meeting_status(meeting, %{status: "expired"})

  defp slot_checked(:recovered, :unchecked), do: {:error, :slot_unchecked}
  defp slot_checked(_transition, _slot), do: :ok

  # The attendee paid for a booking whose slot someone else has since been
  # given, so the booking stays expired and the whole payment goes back.
  # The payment is marked paid, as it truly was, and the refund is left to
  # `RefundLatePayment`, inserted in this same transaction: a Stripe call
  # made here would hold the row locks for as long as Stripe takes, and a
  # lasting Stripe failure would roll back every delivery of this event
  # while the money sat unseen. Once this commits, the booking is on the
  # host's outstanding-refunds list until the refund goes through.
  #
  # The refund needs the charge id, which is backfilled beforehand, outside
  # the transaction, since that is a Stripe call. A backfill that fails does
  # not hold the payment back: it is committed paid with its job all the
  # same, and the job backfills the charge id before it refunds, retrying
  # until Stripe supplies it. Left uncommitted instead, the payment would
  # stay `failed`, off the host's outstanding refunds, once Stripe stopped
  # redelivering this event.
  defp refund_late_payment(payment, event_id, object) do
    backfill_charge_id(payment, object)

    LockedPayment.run(payment, event_id, fn locked ->
      with {:ok, meeting} <- lock_meeting(locked.meeting_id),
           {:proceed, :recovered} <- check_transition(meeting, locked),
           {:ok, paid} <- mark_paid(locked, event_id, object),
           {:ok, _job} <- Oban.insert(RefundLatePayment.new_for(paid.id)) do
        {:ok, {:refund_scheduled, paid, meeting}}
      else
        {:error, _reason} = error -> error
        _no_longer_recoverable -> {:ok, :no_op}
      end
    end)
  end

  # Payment clearing does not always mean the booking is on. The gate
  # decision is read from the meeting row rather than re-derived from the
  # live meeting type: `approval_requested_at` being stamped is the record
  # of the promise shown to the invitee on the booking form
  # (`Policy.approval_attributes/2` stamps it at submission, even on the
  # paid path), and a host toggling `requires_approval` while a Stripe
  # Checkout session sits open — it can stay open 24h — must not silently
  # change what that invitee was told. Where the row was gated, the paid
  # booking moves into the approval gate rather than straight to confirmed,
  # and the host's clock starts here — they are only asked once the money
  # has actually cleared. Only the clock's *start* moves: its length is the
  # window stamped on the row at submission, replayed by
  # `Approval.restart_deadline/2`, so a host who set a 72-hour window still
  # gets 72 hours on a paid booking. Declining or letting it lapse refunds the full
  # remaining balance directly (`Meetings.Approval.after_release/1`); there
  # is no cancellation pipeline involved, because the attendee never got a
  # confirmed meeting to weigh a partial refund against. The confirm branch
  # explicitly nulls both approval columns rather than leaving them
  # untouched, so a row that reaches "confirmed" never carries a stale
  # approval clock alongside it.
  defp post_payment_status(%{approval_requested_at: %DateTime{}} = meeting) do
    requested_at = DateTime.truncate(Clock.utc_now(), :second)

    %{
      status: "awaiting_approval",
      approval_requested_at: requested_at,
      approval_deadline_at: Approval.restart_deadline(meeting, requested_at)
    }
  end

  defp post_payment_status(_meeting),
    do: %{status: "confirmed", approval_requested_at: nil, approval_deadline_at: nil}

  # Scheduled inside the same DB transaction as `mark_paid`/the meeting
  # transition: `CalendarJobs.schedule_job/2` inserts through Oban's
  # configured repo, which is this same `Repo`, so the insert commits
  # atomically with the payment/meeting state change. If the insert fails
  # (a transient DB error, not the absorbed unique-constraint conflict —
  # see `CalendarJobs.schedule_job/2`), rolling back here leaves the
  # booking_payment "pending" and the meeting "awaiting_payment", so a
  # Stripe redelivery of this same event — no longer blocked by the
  # `last_event_id` replay guard, since that write rolled back too — or the
  # next `ReconcileAwaitingPayments` sweep can retry the whole transition.
  defp schedule_calendar_creation(meeting) do
    case CalendarJobs.schedule_job(meeting, "create") do
      {:ok, _status} = ok ->
        ok

      {:error, reason} ->
        Logger.error("checkout.session.completed: failed to schedule calendar job",
          meeting_id: meeting.id,
          reason: LogFormat.reason(reason)
        )

        {:error, reason}
    end
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
  #   :no_op     — meeting already in a non-recoverable terminal state; skip
  defp check_transition(%{status: "awaiting_payment"}, _payment), do: {:proceed, :advanced}
  defp check_transition(%{status: "expired"}, %{status: "failed"}), do: {:proceed, :recovered}

  defp check_transition(_meeting, _payment), do: :no_op

  defp mark_paid(payment, event_id, object) do
    case BookingPaymentQueries.update(payment, %{
           status: paid_status(payment.status),
           paid_at: DateTime.utc_now(:second),
           stripe_payment_intent_id: object["payment_intent"],
           last_event_id: event_id
         }) do
      {:ok, updated} = result ->
        Telemetry.emit_status_changed(payment.status, updated.status, :webhook_paid)
        result

      {:error, _changeset} = err ->
        err
    end
  end

  # A dispute can land before this completed event (the charge is disputed the
  # instant it is captured). When it has, the row is already `disputed` — record
  # the payment_intent and timestamp but keep the dispute status rather than
  # clobbering it back to `paid`.
  defp paid_status("disputed"), do: "disputed"
  defp paid_status(_status), do: "paid"

  defp emit_payment_succeeded(paid, meeting) do
    :telemetry.execute(
      [:tymeslot, :meeting_payments, :booking_payment, :succeeded],
      %{count: 1},
      %{currency: paid.currency, has_video: not is_nil(meeting.video_integration_id)}
    )
  end

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
