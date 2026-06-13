defmodule Tymeslot.Meetings.ExternalCalendarChanges do
  @moduledoc """
  Applies externally detected calendar changes to the meeting lifecycle.

  When a calendar sync worker detects that a provider event linked to a
  Tymeslot meeting was deleted or modified externally, the Calendar context
  delegates here (via `Tymeslot.Meetings.apply_external_calendar_change/4`).
  This module owns the meeting-side consequences: updating the
  `calendar_sync_status`, auto-cancelling the meeting on external deletion
  (with status revert if cancellation fails, so the next sync retries the
  whole operation), and notifying the host about external modifications.

  Detection of changes stays in the Calendar context — this module never
  talks to calendar providers or the event cache.
  """

  require Logger

  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.Emails.EmailService
  alias Tymeslot.Meetings.MeetingCalendarQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting

  @type signal :: :deleted | :modified

  @doc """
  Applies an external calendar change signal to the linked meeting, if any.

  - `calendar_integration_id` — the calendar integration the event belongs to
  - `provider_event_id` — the provider-native event ID (may be `nil` for CalDAV)
  - `uid` — the iCal UID of the event (may be `nil` for Outlook deleted events)
  - `signal` — `:deleted` or `:modified`

  Returns `:ok` when no action was needed (no linked meeting, already
  up-to-date) or when the status change and its side effects succeeded.
  """
  @spec apply_change(integer(), String.t() | nil, String.t() | nil, signal()) ::
          :ok | {:error, term()}
  def apply_change(calendar_integration_id, provider_event_id, uid, signal) do
    case find_linked_meeting(calendar_integration_id, provider_event_id, uid) do
      {:ok, meeting} ->
        apply_status_change(meeting, status_for(signal), signal)

      {:error, :not_found} ->
        :ok
    end
  end

  @doc """
  Looks up a meeting linked to a calendar event by provider event ID or UID.

  Returns `{:ok, meeting}` if a linked meeting is found, `{:error, :not_found}`
  otherwise. Tries `provider_event_id` first, falls back to `uid`.
  """
  @spec find_linked_meeting(integer(), String.t() | nil, String.t() | nil) ::
          {:ok, Meeting.t()} | {:error, :not_found}
  def find_linked_meeting(calendar_integration_id, provider_event_id, uid) do
    cond do
      not is_nil(provider_event_id) ->
        MeetingCalendarQueries.get_by_provider_event_id(
          calendar_integration_id,
          provider_event_id
        )

      not is_nil(uid) ->
        MeetingCalendarQueries.get_by_uid_and_integration(calendar_integration_id, uid)

      true ->
        {:error, :not_found}
    end
  end

  @spec status_for(signal()) :: String.t()
  defp status_for(:deleted), do: "externally_deleted"
  defp status_for(:modified), do: "externally_modified"

  @spec apply_status_change(Meeting.t(), String.t(), signal()) :: :ok | {:error, term()}
  defp apply_status_change(meeting, "externally_deleted", :deleted) do
    case MeetingCalendarQueries.update_calendar_sync_status_if_changed(
           meeting.id,
           "externally_deleted"
         ) do
      {:ok, %{} = updated_meeting} ->
        Logger.info("Calendar sync status updated",
          meeting_id: meeting.id,
          signal: :deleted,
          new_status: "externally_deleted"
        )

        auto_cancel(meeting, updated_meeting)

      {:ok, :already_set} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to update calendar sync status",
          meeting_id: meeting.id,
          signal: :deleted,
          error: reason
        )

        {:error, reason}
    end
  end

  defp apply_status_change(meeting, new_status, signal) do
    # Use conditional update to prevent duplicate emails when the same
    # signal arrives twice (e.g., webhook retry or concurrent reconciliation).
    case MeetingCalendarQueries.update_calendar_sync_status_if_changed(meeting.id, new_status) do
      {:ok, %{} = updated_meeting} ->
        Logger.info("Calendar sync status updated",
          meeting_id: meeting.id,
          signal: signal,
          new_status: new_status
        )

        notify_host(updated_meeting, signal)

      {:ok, :already_set} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to update calendar sync status",
          meeting_id: meeting.id,
          signal: signal,
          error: reason
        )

        {:error, reason}
    end
  end

  # Auto-cancel triggers full notification to both parties. If cancellation
  # fails, revert the sync status so the next reconciliation attempt retries
  # the whole operation.
  defp auto_cancel(meeting, updated_meeting) do
    case Cancel.execute_external(updated_meeting) do
      {:ok, _cancelled} ->
        :ok

      {:error, reason} ->
        Logger.warning("Auto-cancel failed, reverting sync status for retry",
          meeting_id: meeting.id,
          reason: reason
        )

        case MeetingCalendarQueries.clear_calendar_sync_status(meeting.id) do
          {:ok, _meeting} ->
            :ok

          {:error, revert_reason} ->
            Logger.error("Failed to revert sync status after cancel failure",
              meeting_id: meeting.id,
              revert_reason: revert_reason
            )
        end

        {:error, reason}
    end
  end

  @spec notify_host(Meeting.t(), signal()) :: :ok
  defp notify_host(meeting, signal) do
    case EmailService.send_external_booking_change(meeting, meeting.organizer_email, signal) do
      {:ok, _result} ->
        Logger.info("External booking change notification sent",
          meeting_id: meeting.id,
          signal: signal
        )

        :ok

      {:error, reason} ->
        Logger.warning("Failed to send external booking change notification",
          meeting_id: meeting.id,
          reason: reason
        )

        :ok
    end
  end
end
