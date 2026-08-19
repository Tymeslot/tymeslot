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
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Notifications.Orchestrator
  alias Tymeslot.Workers.VideoSyncWorker

  @doc """
  Cancels a meeting by its ID.

  This includes:
  1. Updating meeting status in database
  2. Cancelling calendar event
  3. Deleting pending reminder email jobs
  4. Sending cancellation emails

  Returns {:ok, meeting} or {:error, reason}
  """
  @spec execute(String.t()) :: {:ok, Meeting.t()} | {:error, atom() | String.t()}
  def execute(meeting_id) when is_binary(meeting_id) do
    case MeetingQueries.get_meeting_by_uid(meeting_id) do
      {:ok, meeting} -> execute(meeting)
      {:error, :not_found} -> {:error, :meeting_not_found}
    end
  end

  @spec execute(Meeting.t()) :: {:ok, Meeting.t()} | {:error, atom() | String.t()}
  def execute(%Meeting{status: "cancelled"} = meeting) do
    Logger.info("Skipping cancellation for already-cancelled meeting",
      meeting_id: meeting.id,
      uid: meeting.uid
    )

    {:error, "Meeting is already cancelled"}
  end

  def execute(%Meeting{} = meeting) do
    # Validate using Policy module (includes time checks)
    case Policy.can_cancel_meeting?(meeting) do
      :ok ->
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

      {:error, reason} ->
        Logger.warning("Meeting cancellation blocked by policy",
          meeting_id: meeting.id,
          reason: reason
        )

        {:error, reason}
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

  Returns :ok or {:error, reason}
  """
  @spec validate_cancellation(Meeting.t()) :: :ok | {:error, String.t()}
  def validate_cancellation(meeting) do
    Policy.can_cancel_meeting?(meeting)
  end

  # Private functions

  defp auto_cancel_external(meeting) do
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

    case MeetingQueries.update_meeting(meeting, attrs) do
      {:ok, updated_meeting} ->
        Logger.info("Meeting status updated to cancelled",
          meeting_id: meeting.id
        )

        AvailabilityCache.invalidate_for_user(updated_meeting.organizer_user_id)
        stop_approval_clock(meeting)
        {:ok, updated_meeting}

      {:error, changeset} ->
        Logger.error("Failed to update meeting status",
          meeting_id: meeting.id,
          errors: inspect(changeset.errors)
        )

        {:error, "Failed to update meeting status"}
    end
  end

  # An invitee who withdraws a request they are still waiting on leaves two
  # jobs behind: a nudge asking the host to answer, and an expiry to release a
  # slot already released. Neither is harmless — the nudge asks a real person
  # to decide something that no longer exists.
  #
  # Keyed on the status the meeting had *before* cancelling, because after it
  # the meeting no longer looks like a held request.
  defp stop_approval_clock(meeting) do
    if MeetingState.awaiting_approval?(meeting) do
      Orchestrator.cancel_request_notifications(meeting)
    end

    :ok
  end

  defp update_meeting_status_external(meeting) do
    attrs = %{
      status: "cancelled",
      cancelled_at: DateTime.truncate(Clock.utc_now(), :second),
      cancellation_reason: "Cancelled externally via calendar sync"
    }

    case MeetingQueries.update_meeting(meeting, attrs) do
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
        Logger.warning("Failed to send cancellation notifications",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        # Don't fail cancellation if notifications fail
        :ok
    end
  end
end
