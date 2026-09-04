defmodule Tymeslot.Bookings.Cancel do
  @moduledoc """
  Orchestrates the booking cancellation process.
  Handles meeting status updates, calendar event deletion, and notifications.
  """

  require Logger

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Workers.VideoSyncWorker

  @doc """
  Cancels a meeting by its ID.

  This includes:
  1. Updating meeting status in database
  2. Cancelling calendar event
  3. Deleting pending reminder email jobs
  4. Sending cancellation emails

  Returns {:ok, meeting} or {:error, reason}

  Accepts the same `opts` as `validate_cancellation/2`; see there for
  `:caller`.
  """
  @spec execute(String.t() | Meeting.t(), keyword()) ::
          {:ok, Meeting.t()} | {:error, atom() | String.t()}
  def execute(meeting_or_uid, opts \\ [])

  def execute(meeting_id, opts) when is_binary(meeting_id) do
    case MeetingQueries.get_meeting_by_uid(meeting_id) do
      {:ok, meeting} -> execute(meeting, opts)
      {:error, :not_found} -> {:error, :meeting_not_found}
    end
  end

  def execute(%Meeting{status: "cancelled"} = meeting, _opts) do
    Logger.info("Skipping cancellation for already-cancelled meeting",
      meeting_id: meeting.id,
      uid: meeting.uid
    )

    {:error, "Meeting is already cancelled"}
  end

  def execute(%Meeting{} = meeting, opts) do
    # Validation covers the Policy time checks plus the group-meeting guard.
    case validate_cancellation(meeting, opts) do
      :ok -> execute_permitted(meeting)
      {:error, reason} -> policy_blocked(meeting, reason)
    end
  end

  # A held request is not a confirmed booking being called off — it is the
  # invitee withdrawing before the host ever agreed to it. That transition
  # belongs to `Approval`, which guards it against the same race an approval,
  # a decline or the expiry sweep can win, and which owns the refund rule for
  # a request that never became a meeting. Only the notification stays here:
  # `Approval.withdraw/2` does not send one, since decline and expire each
  # need their own wording and withdrawal needs neither.
  defp execute_permitted(meeting) do
    if MeetingState.awaiting_approval?(meeting) do
      withdraw_held_request(meeting)
    else
      cancel_confirmed_meeting(meeting)
    end
  end

  defp withdraw_held_request(meeting) do
    Logger.info("Withdrawing held booking request",
      meeting_id: meeting.id,
      uid: meeting.uid
    )

    with {:ok, released} <- Approval.withdraw(meeting),
         :ok <- send_cancellation_notifications(released) do
      {:ok, released}
    else
      {:error, reason} = error ->
        Logger.error("Failed to withdraw booking request",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        error
    end
  end

  defp cancel_confirmed_meeting(meeting) do
    Logger.info("Cancelling meeting",
      meeting_id: meeting.id,
      uid: meeting.uid
    )

    with {:ok, updated_meeting} <- update_meeting_status(meeting),
         :ok <- Meetings.cancel_calendar_event(updated_meeting),
         :ok <- delete_provider_video_room(updated_meeting),
         :ok <- send_cancellation_notifications(updated_meeting) do
      {:ok, updated_meeting}
    else
      {:error, reason} = error ->
        Logger.error("Failed to cancel meeting",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        error
    end
  end

  defp policy_blocked(meeting, reason) do
    Logger.warning("Meeting cancellation blocked by policy",
      meeting_id: meeting.id,
      reason: reason
    )

    {:error, reason}
  end

  @doc """
  Runs the side effects of a cancellation whose status flip has already been
  committed by the caller: calendar event deletion, provider video cleanup,
  and the cancellation notifications.

  `execute/1` flips the status itself, which is right for a host cancelling a
  whole meeting. It is wrong for the last participant leaving a group slot:
  there, the flip must happen inside the seat transaction, under the meeting
  row lock, or a concurrent booker can join the slot in the window between the
  seat committing and the meeting being cancelled. `Tymeslot.Bookings.CancelSeat`
  therefore commits the flip itself and calls this to finish the job.
  """
  @spec finalise_cancellation(Meeting.t()) :: :ok
  def finalise_cancellation(%Meeting{} = meeting) do
    AvailabilityCache.invalidate_for_user(meeting.organizer_user_id)

    with :ok <- Meetings.cancel_calendar_event(meeting),
         :ok <- delete_provider_video_room(meeting) do
      send_cancellation_notifications(meeting)
    else
      {:error, reason} ->
        Logger.error("Failed to finalise cancellation of emptied group meeting",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  @doc """
  Cancels a meeting due to external calendar deletion.

  Bypasses policy checks (external deletions may arrive for past meetings)
  and skips calendar event deletion (the event is already gone). Only
  proceeds if the meeting still expects a provider event to exist (see
  `MeetingState.expects_calendar_event?/1`) — a void slot, such as a
  pending reschedule request, legitimately has no event, so its absence
  must not trigger an auto-cancel.

  Returns {:ok, meeting} or {:error, reason}
  """
  @spec execute_external(Meeting.t()) :: {:ok, Meeting.t()} | {:error, atom() | String.t()}
  def execute_external(%Meeting{} = meeting) do
    if MeetingState.expects_calendar_event?(meeting) do
      auto_cancel_external(meeting)
    else
      Logger.info("Skipping auto-cancel for externally deleted meeting",
        meeting_id: meeting.id,
        status: meeting.status
      )

      {:ok, meeting}
    end
  end

  @doc """
  Validates if a meeting can be cancelled.
  Delegates to Policy module for consistent validation.

  `opts`:
    * `:caller` — pass `:organizer` for an authenticated organiser cancelling
      the whole meeting from their own dashboard. Any other value (including
      the default, no opts) is treated as the public, participant-facing
      surface and refuses a live group meeting — see `refuse_group_meeting/2`.

  Returns :ok or {:error, reason}
  """
  @spec validate_cancellation(Meeting.t(), keyword()) :: :ok | {:error, atom() | String.t()}
  def validate_cancellation(meeting, opts \\ []) do
    with :ok <- Policy.can_cancel_meeting?(meeting) do
      refuse_group_meeting(meeting, opts)
    end
  end

  # Private functions

  # A group slot is shared, so flipping the meeting row to "cancelled" here
  # would cancel every other participant's seat, not just whoever is asking.
  # That is exactly what a converted booker's old (pre-conversion) cancel
  # link resolves to: it addresses the meeting by its uid, not by a seat's
  # `management_token`, and by the time it is followed the meeting may carry
  # other live participants who never agreed to any of this. That public,
  # unauthenticated surface (`/:username/meeting/:uid/cancel`) never passes
  # `caller: :organizer`, so it is refused by default; an authenticated
  # organiser cancelling the whole meeting from their own dashboard is a
  # deliberate, distinct action and opts in explicitly.
  #
  # Participants cancel their own seat through `Tymeslot.Bookings.CancelSeat`,
  # which never reaches here. `Tymeslot.Bookings.SeatRelease` legitimately
  # cancels the meeting itself once its last seat is released, but it flips
  # the status directly under the meeting row lock and calls
  # `finalise_cancellation/1` to finish the job — it does not go through
  # `execute/1`, so it is unaffected by this guard regardless of `opts`.
  defp refuse_group_meeting(meeting, opts) do
    if Meetings.group?(meeting) and Keyword.get(opts, :caller) != :organizer do
      {:error, :group_meeting_not_cancellable}
    else
      :ok
    end
  end

  # Same split as `execute_permitted/1`: the host deleting the tentative hold
  # from their own calendar is, for a held request, indistinguishable from
  # the invitee withdrawing it — nobody answered, the slot is simply free
  # again — so it goes through the same guarded `Approval.withdraw/2` rather
  # than the plain changeset write, and for the same reason: without it this
  # auto-cancel skipped the approval clock entirely, leaving the nudge and
  # the expiry sweep armed against a meeting already gone, and refunding
  # nothing for a request that was paid for.
  defp auto_cancel_external(meeting) do
    if MeetingState.awaiting_approval?(meeting) do
      withdraw_held_request_external(meeting)
    else
      cancel_confirmed_meeting_external(meeting)
    end
  end

  defp withdraw_held_request_external(meeting) do
    Logger.info("Auto-withdrawing externally deleted booking request",
      meeting_id: meeting.id,
      uid: meeting.uid
    )

    with {:ok, released} <-
           Approval.withdraw(meeting,
             cancellation_reason: "Cancelled externally via calendar sync"
           ),
         :ok <- send_cancellation_notifications(released) do
      {:ok, released}
    else
      {:error, reason} = error ->
        Logger.error("Failed to auto-withdraw externally deleted booking request",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        error
    end
  end

  defp cancel_confirmed_meeting_external(meeting) do
    Logger.info("Auto-cancelling externally deleted meeting",
      meeting_id: meeting.id,
      uid: meeting.uid
    )

    with {:ok, updated_meeting} <- update_meeting_status_external(meeting),
         :ok <- delete_provider_video_room(updated_meeting),
         :ok <- send_cancellation_notifications(updated_meeting) do
      {:ok, updated_meeting}
    else
      {:error, reason} = error ->
        Logger.error("Failed to auto-cancel externally deleted meeting",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        error
    end
  end

  defp update_meeting_status(meeting) do
    attrs = %{
      status: "cancelled",
      cancelled_at: DateTime.truncate(Clock.utc_now(), :second)
    }

    case MeetingQueries.update_meeting_status(meeting, attrs) do
      {:ok, updated_meeting} ->
        Logger.info("Meeting status updated to cancelled",
          meeting_id: meeting.id
        )

        AvailabilityCache.invalidate_for_user(updated_meeting.organizer_user_id)
        {:ok, updated_meeting}

      {:error, changeset} ->
        Logger.error("Failed to update meeting status",
          meeting_id: meeting.id,
          errors: inspect(changeset.errors)
        )

        {:error, "Failed to update meeting status"}
    end
  end

  defp update_meeting_status_external(meeting) do
    attrs = %{
      status: "cancelled",
      cancelled_at: DateTime.truncate(Clock.utc_now(), :second),
      cancellation_reason: "Cancelled externally via calendar sync"
    }

    case MeetingQueries.update_meeting_status(meeting, attrs) do
      {:ok, updated_meeting} ->
        Logger.info("Meeting auto-cancelled via external calendar deletion",
          meeting_id: meeting.id
        )

        AvailabilityCache.invalidate_for_user(updated_meeting.organizer_user_id)
        {:ok, updated_meeting}

      {:error, changeset} ->
        Logger.error("Failed to auto-cancel meeting",
          meeting_id: meeting.id,
          errors: inspect(changeset.errors)
        )

        {:error, "Failed to update meeting status"}
    end
  end

  # Note: the cancellation email produced by this pipeline carries a
  # `STATUS:CANCELLED` ICS attachment (see `Tymeslot.Emails.Templates.AppointmentCancellation`)
  # so the attendee's calendar client marks the event as cancelled. We deliberately
  # do NOT route bookings cancellation through
  # `Tymeslot.Meetings.AttendeeNotifications.event_deleted_confirm/2`: the bookings
  # cancellation email carries user-facing context (cancellation reason, custom copy)
  # that the calendar-update template cannot replicate, and double-routing would
  # deliver two cancellation emails. Sequence tracking on `Meeting` rows is handled
  # directly by the template via `ical_sequence` when needed.
  # Enqueues a supervised, retrying video-sync job so the provider-side meeting
  # (e.g. Zoom) is deleted and doesn't linger in the organiser's account after
  # cancellation. Routed through Oban — not done inline — so a transient Zoom
  # 5xx/429 retries instead of leaving an orphaned meeting. Providers without a
  # server-side meeting object (Google Meet, Teams, MiroTalk, Custom) resolve to
  # :ok inside the job. Whether an integration can still reach the room is
  # decided inside the job by `IntegrationResolver`, not here: a severed
  # `video_integration_id` does not mean the room stopped existing. Never blocks
  # cancellation.
  defp delete_provider_video_room(%Meeting{video_room_id: nil}), do: :ok
  defp delete_provider_video_room(%Meeting{organizer_user_id: nil}), do: :ok

  defp delete_provider_video_room(%Meeting{} = meeting) do
    case VideoSyncWorker.enqueue(meeting.id, "delete") do
      {:ok, _status} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue provider video deletion on cancellation",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp send_cancellation_notifications(meeting) do
    case Events.meeting_cancelled(meeting) do
      {:ok, _result} ->
        Logger.info("Cancellation emails sent", meeting_id: meeting.id)
        :ok

      {:error, reason} ->
        # A cancellation that notifies nobody is a real defect, not a
        # routine hiccup, so this is logged loudly. It still does not fail
        # the cancellation itself: the meeting is already cancelled and
        # blocking that on email delivery would strand the caller.
        Logger.error("Failed to send cancellation notifications",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        # Don't fail cancellation if notifications fail
        :ok
    end
  end
end
