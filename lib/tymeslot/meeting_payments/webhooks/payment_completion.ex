defmodule Tymeslot.MeetingPayments.Webhooks.PaymentCompletion do
  @moduledoc """
  The steps a completed checkout takes, shared by the booking of one meeting
  (`Webhooks.CheckoutSessionCompleted`) and of a paid series
  (`Webhooks.SeriesCheckoutCompleted`), so the two cannot confirm a paid
  booking differently: recording the payment paid, the status a paid
  meeting moves to, its calendar job, the host still accepting bookings,
  and the charge id backfilled once committed.
  """

  require Logger

  alias Tymeslot.Auth
  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.ChargeBackfill
  alias Tymeslot.MeetingPayments.Telemetry
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.UniqueInvitation
  alias Tymeslot.Meetings.UniqueSlot

  # Best effort: a failure is logged and the payment transition stands. For
  # a late payment being refunded, `RefundLatePayment` backfills again before
  # it refunds.
  @spec backfill_charge_id(BookingPaymentSchema.t(), map()) :: :ok
  def backfill_charge_id(payment, object) do
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

  # A host whose account waits to be deleted takes no booking, even one whose
  # checkout was opened before the deletion was requested.
  @spec host_accepting(map()) :: :ok | {:refuse, :host_pending_deletion, map()}
  def host_accepting(%{organizer_user_id: user_id} = meeting) when is_integer(user_id) do
    if Auth.deletion_pending?(user_id),
      do: {:refuse, :host_pending_deletion, meeting},
      else: :ok
  end

  def host_accepting(_meeting), do: :ok

  # Payment clearing does not always mean the booking is on. The gate is read
  # from the meeting row, not the live meeting type: `approval_requested_at`
  # records the promise shown to the invitee at submission, and a host
  # toggling `requires_approval` while a Checkout session sits open (up to
  # 24h) must not change it. A gated row moves into the approval gate rather
  # than straight to confirmed, and the host's clock starts here, once the
  # money has cleared; its length is the window stamped at submission
  # (`Approval.restart_deadline/2`). Declining or letting it lapse refunds
  # the full remaining balance directly
  # (`Meetings.ApprovalRefunds.refund_unapproved_request/1`), with no
  # cancellation pipeline: the attendee never had a confirmed meeting to weigh
  # a partial refund against. The confirm branch nulls both approval columns
  # so a :confirmed row never carries a stale approval clock.
  @spec post_payment_status(map()) :: map()
  def post_payment_status(%{approval_requested_at: %DateTime{}} = meeting) do
    requested_at = DateTime.truncate(Clock.utc_now(), :second)

    %{
      status: :awaiting_approval,
      approval_requested_at: requested_at,
      approval_deadline_at: Approval.restart_deadline(meeting, requested_at)
    }
  end

  def post_payment_status(_meeting),
    do: %{status: :confirmed, approval_requested_at: nil, approval_deadline_at: nil}

  # Scheduled inside the same DB transaction as `mark_paid`/the meeting
  # transition: `CalendarJobs.schedule_job/2` inserts through Oban's
  # configured repo, which is this same `Repo`, so the insert commits
  # atomically with the payment/meeting state change. If the insert fails
  # (a transient DB error, not the absorbed unique-constraint conflict —
  # see `CalendarJobs.schedule_job/2`), rolling back here leaves the
  # booking_payment :pending and the meeting :awaiting_payment, so a
  # Stripe redelivery of this same event — no longer blocked by the
  # `last_event_id` replay guard, since that write rolled back too — or the
  # next `ReconcileAwaitingPayments` sweep can retry the whole transition.
  @spec schedule_calendar_creation(MeetingSchema.t()) :: {:ok, term()} | {:error, term()}
  def schedule_calendar_creation(meeting) do
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

  @spec mark_paid(BookingPaymentSchema.t(), String.t(), map()) ::
          {:ok, BookingPaymentSchema.t()} | {:error, Ecto.Changeset.t()}
  def mark_paid(payment, event_id, object) do
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
  defp paid_status(:disputed), do: :disputed
  defp paid_status(_status), do: :paid

  @spec emit_payment_succeeded(BookingPaymentSchema.t(), MeetingSchema.t()) :: :ok
  def emit_payment_succeeded(paid, meeting) do
    :telemetry.execute(
      [:tymeslot, :meeting_payments, :booking_payment, :succeeded],
      %{count: 1},
      %{currency: paid.currency, has_video: not is_nil(meeting.video_integration_id)}
    )
  end

  @doc """
  The outcome of bringing an expired booking back for a late payment
  (`Scheduling.reinstate_with_conflict_check/2`): a slot taken since the
  expiry (a conflict, the slot or invitation index), or an organiser gone,
  calls `refund` to refund the payment instead; anything else is returned
  as it is.
  """
  @spec refund_if_slot_lost(term(), (-> term())) :: term()
  def refund_if_slot_lost({:error, reason}, refund)
      when reason in [:time_conflict, :organizer_required],
      do: refund.()

  def refund_if_slot_lost({:error, %Ecto.Changeset{} = changeset} = error, refund) do
    if UniqueInvitation.violation?(changeset) or UniqueSlot.violation?(changeset),
      do: refund.(),
      else: error
  end

  def refund_if_slot_lost(result, _refund), do: result
end
