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
  alias Tymeslot.Meetings.MeetingState

  @type signal :: :deleted | :modified

  @externally_deleted "externally_deleted"
  @externally_modified "externally_modified"

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

  The fallback runs when the first lookup *misses*, not merely when the ID is
  absent: a CalDAV event carries an href in `provider_event_id`, while the
  meeting it mirrors carries no provider event ID at all and is only reachable
  by UID. Falling back on `nil` alone left those meetings unfindable whenever
  the caller had an href to offer. See `Tymeslot.Meetings.CalendarEventLink`
  for the identity rule this implements.
  """
  @spec find_linked_meeting(integer(), String.t() | nil, String.t() | nil) ::
          {:ok, Meeting.t()} | {:error, :not_found}
  def find_linked_meeting(calendar_integration_id, provider_event_id, uid) do
    with {:error, :not_found} <-
           by_provider_event_id(calendar_integration_id, provider_event_id) do
      by_uid(calendar_integration_id, uid)
    end
  end

  defp by_provider_event_id(_calendar_integration_id, nil), do: {:error, :not_found}

  defp by_provider_event_id(calendar_integration_id, provider_event_id),
    do:
      MeetingCalendarQueries.get_by_provider_event_id(
        calendar_integration_id,
        provider_event_id
      )

  defp by_uid(_calendar_integration_id, nil), do: {:error, :not_found}

  defp by_uid(calendar_integration_id, uid),
    do: MeetingCalendarQueries.get_by_uid_and_integration(calendar_integration_id, uid)

  @spec status_for(signal()) :: String.t()
  defp status_for(:deleted), do: @externally_deleted
  defp status_for(:modified), do: @externally_modified

  # Both signals share the same conditional-update shape and differ only in
  # the status literal and what happens on a successful write, so both are
  # guarded uniformly here. Two things disqualify a meeting:
  #
  # A void slot (e.g. a pending reschedule request) has no live provider event
  # to have been deleted or modified externally — otherwise the async-deletion
  # window around a reschedule request could mislabel our own voiding as an
  # external change.
  #
  # An elapsed slot cannot be acted on at all: see `slot_elapsed?/1`.
  @spec apply_status_change(Meeting.t(), String.t(), signal()) :: :ok | {:error, term()}
  defp apply_status_change(meeting, new_status, signal) do
    cond do
      not MeetingState.expects_calendar_event?(meeting) ->
        ignore(meeting, signal, "meeting has no expected calendar event")

      slot_elapsed?(meeting) ->
        ignore(meeting, signal, "meeting slot has already elapsed")

      true ->
        update_calendar_sync_status(meeting, new_status, signal)
    end
  end

  # A meeting whose slot has already elapsed cannot usefully be updated or
  # cancelled, so neither consequence of an external signal has anywhere to
  # land: the attendee cannot be offered a better time for a slot that is
  # already history, and cancelling it would only mail both parties about a
  # meeting that has been and gone. The host is free to tidy the past in their
  # own calendar; Tymeslot reconciles only bookings that still lie ahead.
  #
  # Without this the reach of a sync is its whole window, not the days around
  # today: a full sync re-reads a year of events at once, so every historical
  # divergence a calendar has accumulated arrives as a fresh batch of
  # "action required" mail about meetings nobody can act on.
  @spec slot_elapsed?(Meeting.t()) :: boolean()
  defp slot_elapsed?(%{end_time: %DateTime{} = end_time}),
    do: DateTime.before?(end_time, DateTime.utc_now())

  defp slot_elapsed?(_meeting), do: false

  @spec ignore(Meeting.t(), signal(), String.t()) :: :ok
  defp ignore(meeting, signal, reason) do
    Logger.info("Ignoring external calendar signal",
      meeting_id: meeting.id,
      signal: signal,
      status: meeting.status,
      reason: reason
    )

    :ok
  end

  defp update_calendar_sync_status(meeting, new_status, signal) do
    # Use conditional update to prevent duplicate emails/cancellations when
    # the same signal arrives twice (e.g., webhook retry or concurrent
    # reconciliation).
    case MeetingCalendarQueries.update_calendar_sync_status_if_changed(meeting.id, new_status) do
      {:ok, %{} = updated_meeting} ->
        Logger.info("Calendar sync status updated",
          meeting_id: meeting.id,
          signal: signal,
          new_status: new_status
        )

        apply_signal_continuation(signal, meeting, updated_meeting)

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

  @spec apply_signal_continuation(signal(), Meeting.t(), Meeting.t()) :: :ok | {:error, term()}
  defp apply_signal_continuation(:deleted, meeting, updated_meeting),
    do: auto_cancel(meeting, updated_meeting)

  defp apply_signal_continuation(:modified, _meeting, updated_meeting),
    do: notify_host(updated_meeting, :modified)

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
