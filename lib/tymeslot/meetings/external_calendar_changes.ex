defmodule Tymeslot.Meetings.ExternalCalendarChanges do
  @moduledoc """
  Applies externally detected calendar changes to the meeting lifecycle.

  When a calendar sync worker detects that a provider event linked to a
  Tymeslot meeting was deleted or modified externally, the Calendar context
  delegates here (via `Tymeslot.Meetings.apply_external_calendar_change/4`).
  This module owns the meeting-side consequences: updating the
  `calendar_sync_status`, auto-cancelling the meeting on external deletion
  (with status revert if cancellation fails, so the next sync retries the
  whole operation), notifying the host about external modifications, and
  clearing that flag again once the two sides agree.

  Detection of changes stays in the Calendar context — this module never
  talks to calendar providers or the event cache.
  """

  require Logger

  alias Tymeslot.Availability
  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Emails.EmailService
  alias Tymeslot.Meetings.MeetingCalendarQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Validation.Constraints
  alias Tymeslot.Workers.VideoSyncWorker

  @type signal :: :deleted | :modified

  @externally_deleted "externally_deleted"
  @externally_modified "externally_modified"

  @max_duration_minutes Constraints.duration_minutes_range().last

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
        apply_change_to_meeting(meeting, signal)

      {:error, :not_found} ->
        :ok
    end
  end

  @doc """
  Applies an external calendar change signal to a meeting already in hand.

  The same work `apply_change/4` does once it has resolved its identifiers,
  for callers that resolved the meeting themselves. A batch reconciling many
  deletions matches them all in one query (see
  `Tymeslot.Meetings.list_meetings_by_calendar_identifiers/2`) rather than
  paying two lookups per event to learn that most of them link to nothing.
  """
  @spec apply_change_to_meeting(Meeting.t(), signal()) :: :ok | {:error, term()}
  def apply_change_to_meeting(%Meeting{} = meeting, signal) do
    apply_status_change(meeting, status_for(signal), signal)
  end

  @doc """
  Follows the host's calendar when they lengthened or shortened a meeting
  there without moving its start: the meeting takes the new end.

  The host made the change, so the new end is accepted even where it now
  overlaps another booking. Availability follows at once, and so does the
  meeting's video room; reminders are timed from the start and render the
  meeting as it stands when they are sent, so they follow without a reschedule.
  The booker, or every participant, and every guest are emailed the new end
  with an updated calendar entry, and the host is told who was
  (`Tymeslot.Notifications.Email.EndChangeEmails`).

  An end at or before the start is no length a meeting can have, and one
  that makes it longer than any meeting type may last
  (`Tymeslot.Validation.Constraints.duration_minutes_range/0`) is more likely
  a slip of the host's mouse than a booking to announce; either event is
  treated as an external modification for the host to look at.
  """
  @spec apply_end_change(Meeting.t(), DateTime.t()) :: :ok | {:error, term()}
  def apply_end_change(%Meeting{} = meeting, %DateTime{} = end_time) do
    cond do
      not MeetingState.expects_calendar_event?(meeting) ->
        ignore(meeting, :end_moved, "meeting has no expected calendar event")

      slot_elapsed?(meeting) ->
        ignore(meeting, :end_moved, "meeting slot has already elapsed")

      not DateTime.after?(end_time, meeting.start_time) ->
        apply_change_to_meeting(meeting, :modified)

      DateTime.diff(end_time, meeting.start_time, :minute) > @max_duration_minutes ->
        apply_change_to_meeting(meeting, :modified)

      true ->
        write_end(meeting, end_time)
    end
  end

  defp write_end(meeting, end_time) do
    case MeetingCalendarQueries.update_end_time(meeting, end_time) do
      {:ok, updated} ->
        Logger.info("Meeting end follows the external calendar",
          meeting_id: meeting.id,
          previous_end_time: meeting.end_time,
          end_time: updated.end_time
        )

        resolve_modification(updated)
        Availability.changed(updated.organizer_user_id)
        sync_video_room(updated)
        announce_end(updated)

      # Rescheduled, cancelled, voided or deleted since the event was read:
      # the end was compared against a meeting that no longer stands, so
      # nothing is written and nothing follows from it.
      {:error, :not_found} ->
        Logger.info("External end change dropped: the meeting changed since it was read",
          meeting_id: meeting.id
        )

        :ok
    end
  end

  # Only from a write that landed, so a change that lost its race announces
  # nothing. The notices wait a little and coalesce (see
  # `EmailScheduler.schedule_end_change_emails/1`); chat channels and webhooks
  # are not told, since the booking did not move.
  defp announce_end(meeting) do
    case EmailScheduler.schedule_end_change_emails(meeting) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to schedule the notices of an external end change",
          meeting_id: meeting.id,
          reason: reason
        )

        :ok
    end
  end

  defp sync_video_room(%{video_room_id: nil}), do: :ok
  defp sync_video_room(%{organizer_user_id: nil}), do: :ok

  defp sync_video_room(meeting) do
    case VideoSyncWorker.enqueue(meeting.id, "update") do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue video room update after an external end change",
          meeting_id: meeting.id,
          reason: reason
        )

        :ok
    end
  end

  @doc """
  Records the end the host's calendar event shows for a meeting at a sync
  that found it in step, as the end a later end change is measured against
  (see `Tymeslot.Integrations.Calendar.TimingChange`). Writes only when it
  differs from the one already recorded; nil (an event with no hours) records
  nothing.
  """
  @spec record_seen_calendar_end(Meeting.t(), DateTime.t() | nil) :: :ok
  def record_seen_calendar_end(_meeting, nil), do: :ok

  def record_seen_calendar_end(%Meeting{seen_calendar_end_time: seen} = meeting, end_time) do
    if seen && DateTime.compare(seen, end_time) == :eq,
      do: :ok,
      else: MeetingCalendarQueries.put_seen_calendar_end(meeting.id, end_time)
  end

  @doc """
  Clears a previously recorded external modification, now that the provider
  event agrees with the meeting again.

  The counterpart of the `:modified` signal, and the reason the flag is not
  one-way. Detection is stateless — a sync pass compares one event against one
  meeting and has no memory of what an earlier pass flagged — so nothing else
  in the system ever takes `"externally_modified"` back off a meeting. A
  divergence that resolved itself (the host put the time back, or our own
  write to the provider finally landed) would otherwise leave the host with a
  permanent badge and a notification that was never withdrawn.

  Deliberately narrow: `"externally_deleted"` is left alone. That signal
  auto-cancels the meeting, and the status is the record of why it was
  cancelled, not a condition that can lapse.
  """
  @spec resolve_modification(Meeting.t()) :: :ok
  def resolve_modification(%{calendar_sync_status: @externally_modified} = meeting) do
    MeetingCalendarQueries.clear_external_modification(meeting.id)

    Logger.info("External calendar modification resolved",
      meeting_id: meeting.id
    )

    :ok
  end

  def resolve_modification(_meeting), do: :ok

  @doc """
  Looks up a meeting linked to a calendar event by provider event ID or UID.

  Returns `{:ok, meeting}` if a linked meeting is found, `{:error, :not_found}`
  otherwise. Tries `provider_event_id` first, then matches the event's `uid`
  against the meeting's `calendar_uid`.

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
    do: MeetingCalendarQueries.get_by_calendar_uid_and_integration(calendar_integration_id, uid)

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

  @spec ignore(Meeting.t(), signal() | :end_moved, String.t()) :: :ok
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

      # Cancelled through some other path while this deletion was being
      # handled; that path already told everyone, so there is nothing to retry.
      {:error, :already_cancelled} ->
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
