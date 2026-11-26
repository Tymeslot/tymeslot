defmodule Tymeslot.Meetings.ApprovalRelease do
  @moduledoc """
  The release half of the manual-approval gate: every exit that ends a held
  request without a meeting (`decline/2`, `expire/1`, `withdraw/2`).

  `Tymeslot.Meetings.Approval` is the entry point and delegates these
  functions here; its moduledoc explains what each exit means and why they
  all race one another. Every release goes through the same single guarded
  write as an approval, `MeetingTransitionQueries.transition_from_awaiting_approval/2`,
  so exactly one exit wins.
  """

  require Logger

  alias Tymeslot.Availability
  alias Tymeslot.BookingSeries.Approval, as: SeriesApproval
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.ApprovalRefunds
  alias Tymeslot.Meetings.CommittedStep
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.MeetingTransitionQueries
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Notifications.Orchestrator
  alias Tymeslot.Validation.Constraints
  alias Tymeslot.Workers.VideoSyncWorker

  @doc """
  Declines a held booking, releasing the slot.

  `reason` is the host's optional note to the invitee; `nil` and an empty
  string both mean "no reason given" and are stored as `nil` so the templates
  have one absence to test rather than two.
  """
  @spec decline(Meeting.t(), String.t() | nil) :: {:ok, Meeting.t()} | {:error, Approval.error()}
  def decline(%Meeting{} = meeting, reason \\ nil) do
    case SeriesApproval.for_session(meeting, {:decline, reason}) do
      :not_in_series ->
        now = Clock.utc_now()
        release(meeting, :cancelled, decline_changes(reason, now), now)

      answered ->
        answered
    end
  end

  @doc "What a decline writes besides its status: the reason, capped, and when."
  @spec decline_changes(String.t() | nil, DateTime.t()) :: keyword()
  def decline_changes(reason, %DateTime{} = now) do
    [
      decline_reason: normalise_reason(reason),
      approval_declined_at: DateTime.truncate(now, :second)
    ]
  end

  @doc """
  Releases a held booking whose deadline has passed.

  Distinct from `decline/2` only in the status recorded and, downstream, in
  what the invitee is told. Both free the slot identically. The request is
  dated as resolved at its deadline (`MeetingState.lapsed_at/2`), however
  late this runs.
  """
  @spec expire(Meeting.t()) :: {:ok, Meeting.t()} | {:error, Approval.error()}
  def expire(%Meeting{} = meeting) do
    case SeriesApproval.for_session(meeting, :expire) do
      :not_in_series ->
        ended_at = MeetingState.lapsed_at(meeting.approval_deadline_at, Clock.utc_now())
        release(meeting, :expired, [], ended_at)

      answered ->
        answered
    end
  end

  @doc """
  Withdraws a held request outside of the host's own decision: the invitee
  changed their mind, or an external actor (the host deleting the tentative
  hold from their own calendar) is treated as having withdrawn it on their
  behalf. `Bookings.Cancel` is the only caller.

  Guarded exactly like `decline/2` and `expire/1` — the same
  `transition_from_awaiting_approval/2` — so a withdrawal cannot race a
  host's answer or the expiry sweep into overwriting `:confirmed` back to
  `:cancelled`, and cannot double-refund a request the sweep already
  released. Neither `approval_resolved_at` nor `approval_declined_at` is set:
  the first means "the host decided" and the second "the host refused", and a
  withdrawal is neither. `declined?/1` is what the request page and the
  webhook payload ask, so leaving both unset is what keeps a withdrawal from
  being reported as a decline.

  `extra_changes` lets `Bookings.Cancel` record why (e.g. an external
  calendar deletion) without this module knowing about that reason itself,
  and say who withdrew it: `withdrawn_by: :calendar` for an external
  deletion, which a series is told as the host's cancellation, and the
  default `:attendee` otherwise.
  Notification is deliberately not sent from here: `Bookings.Cancel` sends
  its own ordinary cancellation email for every exit it owns, and decline/
  expire's host-facing wording would be wrong for a withdrawal.
  """
  @spec withdraw(Meeting.t(), keyword()) :: {:ok, Meeting.t()} | {:error, Approval.error()}
  def withdraw(%Meeting{} = meeting, extra_changes \\ []) do
    {withdrawn_by, extra_changes} = Keyword.pop(extra_changes, :withdrawn_by, :attendee)

    case SeriesApproval.for_session(meeting, {:withdraw, withdrawn_by, extra_changes}) do
      :not_in_series -> withdraw_one(meeting, extra_changes)
      answered -> answered
    end
  end

  defp withdraw_one(meeting, extra_changes) do
    now = DateTime.truncate(Clock.utc_now(), :second)
    changes = [status: :cancelled, cancelled_at: now] ++ extra_changes

    with_released_meeting(meeting, changes, fn released ->
      clear_released_request(released)

      CommittedStep.run(released, "refund unapproved request", fn ->
        ApprovalRefunds.refund_unapproved_request(released)
      end)
    end)
  end

  defp release(meeting, status, extra_changes, %DateTime{} = ended_at) do
    ended_at = DateTime.truncate(ended_at, :second)

    changes =
      [status: status, approval_resolved_at: ended_at, cancelled_at: ended_at] ++ extra_changes

    with_released_meeting(meeting, changes, fn released -> after_release(released) end)
  end

  defp with_released_meeting(meeting, changes, after_fun) do
    case MeetingTransitionQueries.transition_from_awaiting_approval(meeting.id, changes) do
      {:ok, released} ->
        Logger.info("Booking request released",
          meeting_id: released.id,
          status: released.status
        )

        Availability.changed(released.organizer_user_id)
        after_fun.(released)
        {:ok, released}

      {:error, :not_awaiting_approval} = error ->
        Logger.info("Release skipped: request no longer held",
          meeting_id: meeting.id,
          status: meeting.status
        )

        error
    end
  end

  # Everything that must happen once the slot is genuinely free again, in the
  # order that matters: stop the jobs that would contradict the outcome, take
  # the hold off the host's calendar, take the video room off the provider,
  # refund whatever the attendee paid for a booking that never got approved,
  # then tell the invitee, and any guests a reschedule had invited, from email
  # jobs (`Orchestrator.send_request_outcome_notifications/2`). Each step runs through `CommittedStep.run/3` so a crash
  # in one cannot stop the next; none of them may fail the transition, which
  # has already been committed and cannot be undone.
  defp after_release(%Meeting{status: status} = meeting) do
    clear_released_request(meeting)

    CommittedStep.run(meeting, "refund unapproved request", fn ->
      ApprovalRefunds.refund_unapproved_request(meeting)
    end)

    CommittedStep.run(meeting, "announce release", fn -> announce_release(meeting, status) end)

    :ok
  end

  @doc """
  Takes a committed release off its request jobs, the host's calendar and
  the video provider, each step best-effort (see `after_release/1`).
  """
  @spec clear_released_request(Meeting.t()) :: :ok
  def clear_released_request(%Meeting{} = meeting) do
    CommittedStep.run(meeting, "cancel request notifications", fn ->
      Orchestrator.cancel_request_notifications(meeting)
    end)

    CommittedStep.run(meeting, "cancel calendar event", fn ->
      Meetings.cancel_calendar_event(meeting)
    end)

    CommittedStep.run(meeting, "release video room", fn -> release_video_room(meeting) end)
    :ok
  end

  defp announce_release(meeting, :expired), do: Events.meeting_request_expired(meeting)
  defp announce_release(meeting, _declined), do: Events.meeting_declined(meeting)

  # Mirrors `Bookings.Cancel`'s own video cleanup. A held request's video
  # room used to depend entirely on the daily orphan sweep
  # (`OrphanedVideoRoomScanWorker`, via `MeetingListQueries.list_cancelled_with_video_room/2`),
  # which only looks at `status == :cancelled` — so a request released as
  # `:expired` left its room behind forever. Enqueuing the delete directly
  # here, for every release regardless of status, means the room's fate no
  # longer depends on which of the two statuses this happened to end in.
  defp release_video_room(%Meeting{video_room_id: nil}), do: :ok
  defp release_video_room(%Meeting{organizer_user_id: nil}), do: :ok

  defp release_video_room(%Meeting{} = meeting) do
    case VideoSyncWorker.enqueue(meeting.id, "delete") do
      {:ok, _status} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue provider video deletion on request release",
          meeting_id: meeting.id,
          reason: LogFormat.reason(reason)
        )

        :ok
    end
  end

  @doc """
  Whether releasing this request refunds its payment automatically.

  False only for a request that was a confirmed meeting before a reschedule
  sent it back through the gate (see `ApprovalRefunds.refund_unapproved_request/1`). The
  attendee return page asks this too, so what it promises cannot drift from
  what the release does.
  """
  @spec refunds_on_release?(Meeting.t() | map()) :: boolean()
  def refunds_on_release?(%{first_announced_at: %DateTime{}}), do: false
  def refunds_on_release?(_meeting), do: true

  @doc """
  Whether a meeting ended as a held request the host never approved:
  declined (`decline/2`), expired unanswered (`expire/1`), or withdrawn
  before an answer (`withdraw/2`), which includes one cancelled while its
  payment was still awaited. Whether its payment goes back on its own is
  `refunds_on_release?/1`.

  The status cannot say: a decline and a withdrawal are `:cancelled` like
  any cancelled meeting, and an expiry is `:expired` like a lapsed checkout.
  So it is read from what each exit writes. A decline alone stamps
  `approval_declined_at`. An expiry stamps `approval_resolved_at`, which an
  approval stamps too, so an approved meeting whose reschedule request
  lapsed (`reschedule_requested_at`) is not one. A withdrawal stamps
  neither, and is the one cancelled meeting still carrying the
  `approval_requested_at` of a request nobody answered: every way out of
  the gate into a confirmed meeting stamps `approval_resolved_at`, a
  reschedule onto a type without the gate included
  (`Bookings.RescheduleGate`).
  """
  @spec released_request?(Meeting.t() | map()) :: boolean()
  def released_request?(%{status: :cancelled, approval_declined_at: %DateTime{}}), do: true

  def released_request?(%{
        status: :cancelled,
        approval_requested_at: %DateTime{},
        approval_resolved_at: nil
      }),
      do: true

  def released_request?(%{status: :expired, reschedule_requested_at: %DateTime{}}), do: false
  def released_request?(%{status: :expired, approval_resolved_at: %DateTime{}}), do: true
  def released_request?(_meeting), do: false

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
