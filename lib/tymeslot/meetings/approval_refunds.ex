defmodule Tymeslot.Meetings.ApprovalRefunds do
  @moduledoc """
  The refund owed when a held booking request ends without becoming a
  meeting (declined, expired or withdrawn): `refund_unapproved_request/1`.
  Split from `Tymeslot.Meetings.Approval`, which resolves the requests and
  calls in here once a release has committed.
  """

  require Logger

  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.MeetingPayments
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting

  @doc """
  Refunds in full a held request that ended without becoming a meeting —
  unless it was one already.

  A booking that was paid for but never approved gave the attendee nothing,
  so the full remaining balance goes back automatically: there is no
  confirmed meeting to weigh against a partial refund, and so no host-facing
  choice to offer (contrast `Meetings.Cancellation`, which cancels a meeting
  the attendee did get to have and lets the host choose none, partial, or
  full). That contrast breaks for a request that re-entered the gate: a
  reschedule of an already-`"confirmed"`, paid meeting resets it to
  `"awaiting_approval"` (`Tymeslot.Bookings.Reschedule.reenters_gate?/1`), and if that
  re-request is then declined or expires, there genuinely *is* a confirmed
  meeting to weigh against a partial refund — the one the attendee already
  had, activated, and were told about. Auto-refunding it in full would make
  that choice for the host silently, so this checks `first_announced_at` and
  skips the automatic refund when it is set, leaving the payment refundable
  from the dashboard's payments screen instead. A payment row that was never
  actually paid is quietly skipped, since it has nothing to refund.

  It has to be `first_announced_at` and not `announced_at`: the re-gating
  reschedule clears `announced_at` on purpose, so that the host's second
  approval can claim the announcement fan-out for the new time
  (`Bookings.Reschedule`), and reading the claim here would therefore find it
  empty on exactly the meetings this rule is about.

  `Tymeslot.Meetings.Approval` calls it for every way a held request stops
  being held: `decline/2` and `expire/1` (via its `after_release/1`), and
  `withdraw/2`, for an invitee's own withdrawal and for an externally-deleted
  hold. A failed
  refund is logged and never fails the caller's transition, which is already
  committed.
  """
  @spec refund_unapproved_request(Meeting.t()) :: :ok
  def refund_unapproved_request(meeting) do
    case MeetingPayments.payment_for_meeting(meeting.id) do
      %{paid_at: %DateTime{}} = payment -> refund_or_defer(payment, meeting)
      _unpaid_or_missing -> :ok
    end
  end

  defp refund_or_defer(payment, meeting) do
    if Approval.refunds_on_release?(meeting) do
      refund_remaining(payment, meeting)
    else
      Logger.info(
        "Skipping automatic refund: request was a confirmed meeting before re-entering the approval gate",
        meeting_id: meeting.id,
        payment_id: payment.id
      )

      :ok
    end
  end

  defp refund_remaining(payment, meeting) do
    case MeetingPayments.refundable_remaining_cents(payment) do
      0 ->
        :ok

      remaining_cents ->
        issue_release_refund(payment, remaining_cents, meeting)
    end
  end

  defp issue_release_refund(payment, remaining_cents, meeting) do
    case MeetingPayments.issue_refund(payment, remaining_cents) do
      {:ok, _refunded} ->
        :ok

      {:error, reason} ->
        # A failed refund must not undo the already-committed release (see
        # module docs on ordering). The approval window can run up to 336
        # hours, so an expired request can plausibly fall outside Stripe's own
        # refund window; that, and any other Stripe-side failure, ends up
        # here rather than crashing the caller. The attendee has paid for a
        # booking that will not happen, so it is recorded for the operator
        # to refund by hand; a new error raises an admin alert.
        ErrorTracking.report_error(reason, nil, %{
          meeting_id: meeting.id,
          payment_id: payment.id,
          amount_cents: remaining_cents
        })
    end
  end
end
