defmodule Tymeslot.Bookings.Cancel do
  @moduledoc """
  Orchestrates the booking cancellation process.
  Handles meeting status updates, calendar event deletion, and notifications.
  """

  require Logger

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.DatabaseQueries.MeetingQueries
  alias Tymeslot.DatabaseSchemas.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings

  @doc """
  Cancels a meeting by its ID.

  This includes:
  1. Updating meeting status in database
  2. Cancelling calendar event
  3. Sending cancellation emails

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
  Validates if a meeting can be cancelled.
  Delegates to Policy module for consistent validation.

  Returns :ok or {:error, reason}
  """
  @spec validate_cancellation(Meeting.t()) :: :ok | {:error, String.t()}
  def validate_cancellation(meeting) do
    Policy.can_cancel_meeting?(meeting)
  end

  # Private functions

  defp update_meeting_status(meeting) do
    attrs = %{
      status: "cancelled",
      cancelled_at: DateTime.truncate(DateTime.utc_now(), :second)
    }

    case MeetingQueries.update_meeting(meeting, attrs) do
      {:ok, updated_meeting} ->
        Logger.info("Meeting status updated to cancelled",
          meeting_id: meeting.id
        )

        {:ok, updated_meeting}

      {:error, changeset} ->
        Logger.error("Failed to update meeting status",
          meeting_id: meeting.id,
          errors: inspect(changeset.errors)
        )

        {:error, "Failed to update meeting status"}
    end
  end

  defp send_cancellation_notifications(meeting) do
    alias Tymeslot.Notifications.Events

    case Events.meeting_cancelled(meeting) do
      {:ok, _} ->
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
