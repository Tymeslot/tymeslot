defmodule Tymeslot.Meetings.Approval do
  @moduledoc """
  The manual-approval gate: bookings a host holds before agreeing to them.

  A meeting type with `requires_approval` set does not confirm its bookings on
  submission. The meeting is inserted as `"awaiting_approval"`, which occupies
  its slot exactly as a confirmed booking does, and waits for the host to
  answer. Three things can end that wait, and this module owns all three.

  ## Why the transitions live in one module

  Every exit from the gate races every other one. The host can approve in the
  dashboard while the expiry job is firing; they can click Approve twice; a
  colleague can decline from a forwarded email after the host already accepted;
  the invitee can withdraw the request mid-decision. A read-then-write would
  let the second writer overwrite the first, and the failure is not cosmetic —
  it produces a confirmed meeting the host declined, or a released slot the
  host accepted.

  So the status change is a single guarded `UPDATE ... WHERE status =
  'awaiting_approval'` (`MeetingQueries.transition_from_awaiting_approval/2`),
  and nothing else in the codebase writes that status. Exactly one caller wins;
  the rest get `{:error, :not_awaiting_approval}`, which surfaces as "this
  request was already answered" rather than as a failure.

  ## What each exit means

    * `approve/1` — the host agrees. The meeting becomes `"confirmed"` and
      joins the ordinary booking pipeline through `Bookings.Activation`: the
      same video room, the same confirmation emails, the same reminders and
      webhooks an ungated booking would have produced. The invitee's second
      email is deliberately the standard confirmation, so it looks like every
      other Tymeslot booking. Answering after the request's own
      `approval_deadline_at` does not confirm it — see "The deadline" below.

    * `decline/2` — the host says no. The meeting becomes `"cancelled"`, which
      is not a compromise but the accurate status: the slot is released, the
      tentative calendar event removed, and the attendee told. A booking that
      was paid for but never approved gave the attendee nothing, so `release/3`
      refunds the full remaining balance itself rather than deferring to the
      cancellation pipeline, which exists for a meeting the attendee actually
      got to have and offers the host no such choice here. What distinguishes
      a decline from an invitee's own cancellation is `approval_resolved_at`
      together with `decline_reason`.

    * `expire/1` — nobody answered in time. Identical to a decline apart from
      the status (`"expired"`) and the wording the invitee receives: the host
      did not refuse, the window simply lapsed. Silence never means yes.

  ## The deadline

  `deadline_for/2` is capped at the meeting's own start time. A request for a
  meeting in six hours cannot have a twenty-four hour window; it lapses when
  the meeting would have begun, because approving a booking whose slot has
  already passed helps nobody. `approve/1` enforces that deadline itself
  rather than trusting that the expiry sweep gets there first: a host
  answering after the window the invitee was promised gets the same outcome
  the sweep would have produced (the request is released as `"expired"`),
  not a late confirmation.
  """

  require Logger

  alias Tymeslot.Bookings.Activation
  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MeetingPayments
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.MeetingTypes.MeetingTypeSchema, as: MeetingType
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Notifications.Orchestrator
  alias Tymeslot.Validation.Constraints

  @typedoc "Why a transition out of the approval gate did not happen."
  @type error :: :not_awaiting_approval | :meeting_started | :slot_taken

  @doc """
  Whether bookings on this meeting type are held for the host to approve.

  Accepts `nil` so callers that may not have resolved a meeting type — ad-hoc
  host bookings, demo profiles — need no separate branch. No meeting type
  means no gate.
  """
  @spec required?(MeetingType.t() | map() | nil) :: boolean()
  def required?(nil), do: false
  def required?(%{requires_approval: true}), do: true
  def required?(_meeting_type), do: false

  @doc """
  How long the host has to answer, in hours.

  A meeting type storing no window uses the application default rather than
  freezing today's value into every row.
  """
  @spec window_hours(MeetingType.t() | map() | nil) :: pos_integer()
  def window_hours(%{approval_window_hours: hours}) when is_integer(hours) and hours > 0,
    do: hours

  def window_hours(_meeting_type), do: Constraints.default_approval_window_hours()

  @doc """
  When a request made now must be answered by.

  Never later than the meeting's own start time: a slot that has already begun
  cannot be given away, so a request against it stops being answerable then
  rather than at a deadline computed from the window alone.
  """
  @spec deadline_for(MeetingType.t() | map() | nil, DateTime.t(), DateTime.t()) :: DateTime.t()
  def deadline_for(meeting_type, %DateTime{} = requested_at, %DateTime{} = start_time) do
    window_end = DateTime.add(requested_at, window_hours(meeting_type) * 3600, :second)

    window_end
    |> earliest(start_time)
    |> DateTime.truncate(:second)
  end

  @doc """
  Confirms a held booking and hands it to the ordinary booking pipeline.

  Refuses a meeting whose start time has passed: there is nothing left to
  confirm, and the invitee would receive a confirmation for a meeting that
  already did not happen. Declining is the honest action there, and the expiry
  sweep will take it.

  A request answered after its own `approval_deadline_at` is treated the same
  way: the host missed the window the invitee was promised, so this releases
  the request as `"expired"` exactly as the sweep would have, instead of
  confirming a meeting past its deadline. The caller sees
  `{:error, :not_awaiting_approval}` either way — the same race-loss outcome
  shown whenever somebody else answered first — because by the time this
  returns, the request genuinely is no longer awaiting approval.
  """
  @spec approve(Meeting.t()) :: {:ok, Meeting.t()} | {:error, error()}
  def approve(%Meeting{} = meeting) do
    now = Clock.utc_now()

    cond do
      started?(meeting, now) -> {:error, :meeting_started}
      deadline_passed?(meeting, now) -> approve_after_deadline(meeting)
      true -> do_approve(meeting, now)
    end
  end

  defp approve_after_deadline(meeting) do
    case expire(meeting) do
      {:ok, _released} -> {:error, :not_awaiting_approval}
      {:error, _reason} = error -> error
    end
  end

  defp do_approve(meeting, now) do
    case MeetingQueries.transition_from_awaiting_approval(meeting.id,
           status: "confirmed",
           approval_resolved_at: DateTime.truncate(now, :second)
         ) do
      {:ok, confirmed} ->
        Logger.info("Booking request approved", meeting_id: confirmed.id, uid: confirmed.uid)
        AvailabilityCache.invalidate_for_user(confirmed.organizer_user_id)
        Orchestrator.cancel_request_notifications(confirmed)
        confirm_calendar_event(confirmed)
        Activation.activate(confirmed, with_video_room: true)
        {:ok, confirmed}

      {:error, :not_awaiting_approval} = error ->
        Logger.info("Approval skipped: request no longer held",
          meeting_id: meeting.id,
          status: meeting.status
        )

        error

      # Somebody else's booking took the slot while this request sat held. The
      # partial unique index spans `confirmed` and `awaiting_approval` together,
      # so confirming this one would collide with the row that won. The request
      # stays held rather than being released: the host may still be able to
      # decline it deliberately, and the expiry sweep will free it otherwise.
      {:error, :slot_taken} = error ->
        Logger.info("Approval refused: the slot was taken by another booking",
          meeting_id: meeting.id,
          start_time: meeting.start_time
        )

        error
    end
  end

  @doc """
  Declines a held booking, releasing the slot.

  `reason` is the host's optional note to the invitee; `nil` and an empty
  string both mean "no reason given" and are stored as `nil` so the templates
  have one absence to test rather than two.
  """
  @spec decline(Meeting.t(), String.t() | nil) :: {:ok, Meeting.t()} | {:error, error()}
  def decline(%Meeting{} = meeting, reason \\ nil) do
    release(meeting, "cancelled", decline_reason: normalise_reason(reason))
  end

  @doc """
  Releases a held booking whose deadline has passed.

  Distinct from `decline/2` only in the status recorded and, downstream, in
  what the invitee is told. Both free the slot identically.
  """
  @spec expire(Meeting.t()) :: {:ok, Meeting.t()} | {:error, error()}
  def expire(%Meeting{} = meeting) do
    release(meeting, "expired", [])
  end

  defp release(meeting, status, extra_changes) do
    now = DateTime.truncate(Clock.utc_now(), :second)

    changes =
      [status: status, approval_resolved_at: now, cancelled_at: now] ++ extra_changes

    case MeetingQueries.transition_from_awaiting_approval(meeting.id, changes) do
      {:ok, released} ->
        Logger.info("Booking request released",
          meeting_id: released.id,
          uid: released.uid,
          status: status
        )

        AvailabilityCache.invalidate_for_user(released.organizer_user_id)
        after_release(released)
        {:ok, released}

      {:error, :not_awaiting_approval} = error ->
        Logger.info("Release skipped: request no longer held",
          meeting_id: meeting.id,
          status: meeting.status
        )

        error
    end
  end

  # The booking already wrote a tentative event to hold the slot; approving it
  # has to turn that event into a real one. Without this the host's calendar
  # keeps showing a maybe for a meeting they agreed to, and every app reading
  # that calendar — including their colleagues' free/busy — reads it the same
  # way. The builder derives `status` from the meeting, so re-pushing the event
  # is the whole flip.
  #
  # Scheduled unconditionally now, the same way `Bookings.Create` schedules
  # the original "create" job and `Bookings.Reschedule` schedules its own
  # "update": whether there is anything to flip is `CalendarEventSync`'s call,
  # not a pre-check made here. There used to be one — "has an event to flip"
  # tested for a present `provider_event_id` or a `uid` that didn't look like
  # a plain UUID — but CalDAV addresses its event by `uid` alone, and that
  # `uid` *is* the meeting's own id until CalDAV's own create job overwrites
  # it (`CalendarEventSync.put_provider_mapping/2`), so the check passed the
  # UUID test and the gate was permanently false for every CalDAV host: their
  # calendars kept showing TENTATIVE forever regardless of approval. The
  # "update" job this schedules already falls back to uid-addressing, recreates
  # the event on a missing-event 404, and errors out gracefully when there is
  # genuinely no calendar integration to update — so there was nothing this
  # pre-check did that scheduling unconditionally does not already handle.
  #
  # Best-effort, like every other calendar write: the approval is committed and
  # a failed push is retried by the worker rather than undoing it.
  defp confirm_calendar_event(meeting) do
    schedule_calendar_confirm(meeting)
  end

  defp schedule_calendar_confirm(meeting) do
    case CalendarJobs.schedule_job(meeting, "update") do
      {:ok, _status} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule calendar update after approval",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  # Everything that must happen once the slot is genuinely free again, in the
  # order that matters: stop the jobs that would contradict the outcome, take
  # the hold off the host's calendar, refund whatever the attendee paid for a
  # booking that never got approved, then tell the invitee. Each step is
  # best-effort and logged by its own module; none of them may fail the
  # transition, which has already been committed and cannot be undone.
  defp after_release(%Meeting{status: status} = meeting) do
    Orchestrator.cancel_request_notifications(meeting)
    Meetings.cancel_calendar_event(meeting)
    refund_unapproved_request(meeting)
    announce_release(meeting, status)
    :ok
  end

  defp announce_release(meeting, "expired"), do: Events.meeting_request_expired(meeting)
  defp announce_release(meeting, _declined), do: Events.meeting_declined(meeting)

  @doc """
  Refunds in full a held request that ended without becoming a meeting.

  A booking that was paid for but never approved gave the attendee nothing,
  so the full remaining balance goes back automatically: there is no
  confirmed meeting to weigh against a partial refund, and so no host-facing
  choice to offer (contrast `Meetings.Cancellation`, which cancels a meeting
  the attendee did get to have). A payment row that was never actually paid
  is quietly skipped, since it has nothing to refund.

  Public because this rule applies to every way a held request stops being
  held, not only the two this module resolves itself (`decline/2`,
  `expire/1`, via `after_release/1`): an invitee who withdraws the request
  reaches `Bookings.Cancel` instead, and that module calls this directly
  rather than re-deciding the same rule. A failed refund is logged and never
  fails the caller's transition, which is already committed.
  """
  @spec refund_unapproved_request(Meeting.t()) :: :ok
  def refund_unapproved_request(meeting) do
    case MeetingPayments.payment_for_meeting(meeting.id) do
      %{paid_at: %DateTime{}} = payment -> refund_remaining(payment, meeting)
      _unpaid_or_missing -> :ok
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
        # here rather than crashing the caller. Logged only: no entry in
        # `AdminAlerts.AlertTypes`'s registry describes a refund attempt that
        # failed rather than one Stripe already completed, so this is
        # reported to whoever reviews the logs until the registry gains one.
        Logger.error("Failed to refund a released booking request",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp started?(%Meeting{start_time: nil}, _now), do: false

  defp started?(%Meeting{start_time: start_time}, now),
    do: DateTime.compare(now, start_time) != :lt

  defp deadline_passed?(%Meeting{approval_deadline_at: nil}, _now), do: false

  defp deadline_passed?(%Meeting{approval_deadline_at: deadline}, now),
    do: DateTime.compare(now, deadline) != :lt

  defp earliest(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  # Capped here rather than only in the form, because the reason is quoted
  # verbatim into an email to a third party and the two places a host can type
  # one are both client-side limits a request can simply not honour.
  defp normalise_reason(nil), do: nil

  defp normalise_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, Constraints.decline_reason_max_length())
    end
  end
end
