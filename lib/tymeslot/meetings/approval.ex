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

    * `approve/2` — the host agrees. The meeting becomes `"confirmed"` and
      joins the ordinary booking pipeline through `Bookings.Activation`: the
      same video room, the same confirmation emails, the same reminders and
      webhooks an ungated booking would have produced. The invitee's second
      email is deliberately the standard confirmation, so it looks like every
      other Tymeslot booking.

    * `decline/3` — the host says no. The meeting becomes `"cancelled"`, which
      is not a compromise but the accurate status: the slot must be released,
      the tentative calendar event removed, any payment refunded and the
      attendee told, all of which the cancellation pipeline already does. What
      distinguishes a decline from an invitee's own cancellation is
      `approval_resolved_at` together with `decline_reason`.

    * `expire/1` — nobody answered in time. Identical to a decline apart from
      the status (`"expired"`) and the wording the invitee receives: the host
      did not refuse, the window simply lapsed. Silence never means yes.

  ## The deadline

  `deadline_for/2` is capped at the meeting's own start time. A request for a
  meeting in six hours cannot have a twenty-four hour window; it lapses when
  the meeting would have begun, because approving a booking whose slot has
  already passed helps nobody.
  """

  require Logger

  alias Tymeslot.Bookings.Activation
  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.MeetingTypes.MeetingTypeSchema, as: MeetingType
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Notifications.Orchestrator
  alias Tymeslot.Validation.Constraints

  @typedoc "Why a transition out of the approval gate did not happen."
  @type error :: :not_awaiting_approval | :meeting_not_found | :meeting_started

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
  """
  @spec approve(Meeting.t()) :: {:ok, Meeting.t()} | {:error, error()}
  def approve(%Meeting{} = meeting) do
    now = Clock.utc_now()

    if started?(meeting, now) do
      {:error, :meeting_started}
    else
      do_approve(meeting, now)
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
  # Best-effort, like every other calendar write: the approval is committed and
  # a failed push is retried by the worker rather than undoing it.
  defp confirm_calendar_event(%Meeting{provider_event_id: nil}), do: :ok

  defp confirm_calendar_event(meeting) do
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
  # the hold off the host's calendar, then tell the invitee. Each step is
  # best-effort and logged by its own module; none of them may fail the
  # transition, which has already been committed and cannot be undone.
  defp after_release(%Meeting{status: status} = meeting) do
    Orchestrator.cancel_request_notifications(meeting)
    Meetings.cancel_calendar_event(meeting)
    announce_release(meeting, status)
    :ok
  end

  defp announce_release(meeting, "expired"), do: Events.meeting_request_expired(meeting)
  defp announce_release(meeting, _declined), do: Events.meeting_declined(meeting)

  defp started?(%Meeting{start_time: nil}, _now), do: false

  defp started?(%Meeting{start_time: start_time}, now),
    do: DateTime.compare(now, start_time) != :lt

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
