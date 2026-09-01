defmodule Tymeslot.Notifications.Events do
  @moduledoc """
  Defines notification events and their triggers.
  Pure functions for determining what notifications should be sent based on events.
  """

  require Logger

  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Notifications.Orchestrator
  alias Tymeslot.Slack.Dispatcher, as: SlackDispatcher
  alias Tymeslot.Telegram.Dispatcher, as: TelegramDispatcher
  alias Tymeslot.Webhooks.Dispatcher

  @doc """
  Handles meeting creation event.

  Raised at most once per meeting. A booking with a video room defers this
  event to `Tymeslot.Workers.VideoRoomWorker` so the payload can carry the join
  link, and that job announces the booking without one if the room is taking
  too long — a room that then arrives on a later attempt would otherwise fan
  the event out a second time, to every email, webhook, Telegram chat and Slack
  channel subscribed to it.

  The claim is taken before the fan-out rather than after it, so two callers
  racing cannot both dispatch. A fan-out that then fails keeps the claim: every
  channel here is best-effort and none of the callers retry the event, so
  releasing it would buy nothing and would risk announcing twice instead.
  """
  @spec meeting_created(term()) :: {:ok, term()} | {:error, term()}
  def meeting_created(meeting) do
    case MeetingQueries.claim_announcement(Map.get(meeting, :id)) do
      :ok -> dispatch_meeting_created(meeting)
      :already_announced -> already_announced(meeting)
    end
  end

  defp already_announced(meeting) do
    Logger.info("Meeting already announced, skipping the created event",
      meeting_id: Map.get(meeting, :id)
    )

    {:ok, :already_announced}
  end

  defp dispatch_meeting_created(meeting) do
    # Send email notifications
    result =
      send_notifications(:meeting_created, meeting, fn ->
        Orchestrator.schedule_meeting_notifications(meeting)
      end)

    # Dispatch webhooks (don't fail if webhooks fail)
    dispatch_webhooks(:meeting_created, meeting)

    # Dispatch Telegram notifications (don't fail if Telegram fails)
    dispatch_telegram(:meeting_created, meeting)

    # Dispatch Slack notifications (don't fail if Slack fails)
    dispatch_slack(:meeting_created, meeting)

    result
  end

  @doc """
  Handles a booking request being raised on a meeting type requiring approval.

  Fires `meeting.requested` rather than `meeting.created`. Consumers already
  read `meeting.created` as "a confirmed booking exists", and a held request
  is not one; it fires later, when the host approves. Meeting types without
  approval are unaffected and keep firing `meeting.created` on submission.
  """
  @spec meeting_requested(term()) :: {:ok, term()} | {:error, term()}
  def meeting_requested(meeting) do
    result =
      send_notifications(:meeting_requested, meeting, fn ->
        Orchestrator.schedule_request_notifications(meeting)
      end)

    # The host learns about the request through whichever channel they watch,
    # so dispatch is attempted on all three now rather than at approval. Only
    # webhooks can actually carry this event today: the Slack and Telegram
    # integration schemas still cap their selectable `events` at the
    # pre-approval three (`SlackIntegrationSchema`, `TelegramIntegrationSchema`),
    # so no integration can be subscribed to it yet and these two calls find
    # nothing to notify until that allowlist is widened.
    Dispatcher.dispatch(:meeting_requested, meeting)
    TelegramDispatcher.dispatch(:meeting_requested, meeting)
    SlackDispatcher.dispatch(:meeting_requested, meeting)

    result
  end

  @doc """
  Handles a booking request the host refused.

  Distinct from `meeting_cancelled/1` even though the stored status is the
  same. A cancellation tells the invitee a confirmed meeting is off; a decline
  tells them a request was never accepted, and sending the cancellation email
  here would refer to a booking they were explicitly told was not one.
  """
  @spec meeting_declined(term()) :: {:ok, term()} | {:error, term()}
  def meeting_declined(meeting), do: request_ended(meeting, :meeting_declined, :declined)

  @doc """
  Handles a booking request nobody answered before its deadline.
  """
  @spec meeting_request_expired(term()) :: {:ok, term()} | {:error, term()}
  def meeting_request_expired(meeting),
    do: request_ended(meeting, :meeting_request_expired, :expired)

  defp request_ended(meeting, event, variant) do
    result =
      send_notifications(event, meeting, fn ->
        Orchestrator.send_request_outcome_notifications(meeting, variant)
      end)

    Dispatcher.dispatch(event, meeting)
    TelegramDispatcher.dispatch(event, meeting)
    SlackDispatcher.dispatch(event, meeting)

    result
  end

  @doc """
  Handles meeting cancellation event.
  """
  @spec meeting_cancelled(term()) :: {:ok, term()} | {:error, term()}
  def meeting_cancelled(meeting) do
    # Send email notifications
    result =
      send_notifications(:meeting_cancelled, meeting, fn ->
        Orchestrator.send_cancellation_notifications(meeting)
      end)

    # Cancel pending reminders — a cancellation event already tells us the
    # slot is void, so call the canceller directly. Failures are logged but
    # never fail the cancellation itself.
    cancel_reminders(meeting)

    # Dispatch webhooks (don't fail if webhooks fail)
    dispatch_webhooks(:meeting_cancelled, meeting)

    # Dispatch Telegram notifications (don't fail if Telegram fails)
    dispatch_telegram(:meeting_cancelled, meeting)

    # Dispatch Slack notifications (don't fail if Slack fails)
    dispatch_slack(:meeting_cancelled, meeting)

    result
  end

  @doc """
  Handles meeting rescheduling event.
  """
  @spec meeting_rescheduled(term(), term()) :: {:ok, term()} | {:error, term()}
  def meeting_rescheduled(updated_meeting, original_meeting) do
    # Send email notifications
    result =
      send_notifications(:meeting_rescheduled, updated_meeting, fn ->
        Orchestrator.send_reschedule_notifications(updated_meeting, original_meeting)
      end)

    # Re-pin reminders to the new meeting time. This replaces reminder jobs
    # still aimed at the old time and recreates the ones deleted when an
    # organizer reschedule request voided the original slot. Failures are
    # logged but never fail the reschedule itself.
    schedule_reminders(updated_meeting)

    # Dispatch webhooks (don't fail if webhooks fail)
    dispatch_webhooks(:meeting_rescheduled, updated_meeting)

    # Dispatch Telegram notifications (don't fail if Telegram fails)
    dispatch_telegram(:meeting_rescheduled, updated_meeting)

    # Dispatch Slack notifications (don't fail if Slack fails)
    dispatch_slack(:meeting_rescheduled, updated_meeting)

    result
  end

  @doc """
  Handles an organizer's reschedule request: the current time slot becomes
  void, so any pending reminder jobs still pointing at it are cancelled.
  Rebooking (`meeting_rescheduled/2`) recreates them.

  Unlike the other event handlers here, failures are NOT swallowed: voiding
  the slot is a correctness invariant the caller (`Bookings.RescheduleRequest`)
  must be able to react to, not a best-effort side notification.
  """
  @spec reschedule_requested(term()) :: :ok | {:error, term()}
  def reschedule_requested(meeting) do
    cancel_reminders_strict(meeting)
  end

  # The email step is the only one of these dispatches that renders templates
  # in-process, so a payload the templates don't fit raises instead of
  # returning `{:error, _}`. Everything sequenced after it — reminder jobs,
  # webhooks, Telegram, Slack — is best-effort by design, and an escaping
  # exception used to skip all of them while the meeting change itself stood
  # (issue #76: a reschedule that never dispatched `meeting.rescheduled`).
  # Contain it here so one failed channel cannot silence the others; the caller
  # still learns the emails failed through the error tuple it already handles.
  defp send_notifications(event, meeting, fun) do
    fun.()
  rescue
    exception ->
      Logger.error("Notification emails failed",
        event: event,
        meeting_id: Map.get(meeting, :id),
        error: Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, {:notifications_failed, exception}}
  end

  # `Dispatcher.dispatch/2` (and its Telegram/Slack counterparts) resolves an
  # internal event atom to a wire name via `EventTypes.to_event_type/1`, which
  # raises on an atom it doesn't recognise. These three calls sit outside the
  # `send_notifications/3` rescue, on purpose — that rescue is scoped to the
  # in-process email render — so each dispatch gets its own guard: a channel
  # that can't resolve the event name is best-effort like the rest of the
  # fan-out, not a reason to abort the remaining channels or escape into the
  # booking caller.
  defp dispatch_webhooks(event, meeting), do: dispatch_channel(:webhooks, event, meeting)
  defp dispatch_telegram(event, meeting), do: dispatch_channel(:telegram, event, meeting)
  defp dispatch_slack(event, meeting), do: dispatch_channel(:slack, event, meeting)

  defp dispatch_channel(channel, event, meeting) do
    dispatch_fun(channel).(event, meeting)
  rescue
    exception ->
      Logger.error("Channel dispatch failed",
        channel: channel,
        event: event,
        meeting_id: Map.get(meeting, :id),
        error: Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, {:dispatch_failed, exception}}
  end

  defp dispatch_fun(:webhooks), do: &Dispatcher.dispatch/2
  defp dispatch_fun(:telegram), do: &TelegramDispatcher.dispatch/2
  defp dispatch_fun(:slack), do: &SlackDispatcher.dispatch/2

  defp cancel_reminders_strict(meeting) do
    Orchestrator.cancel_reminder_notifications(meeting)
  end

  defp cancel_reminders(meeting) do
    case Orchestrator.cancel_reminder_notifications(meeting) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to cancel reminder jobs",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp schedule_reminders(meeting) do
    case Orchestrator.schedule_reminder_notifications(meeting) do
      :ok ->
        :ok

      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to schedule reminder jobs",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  @doc """
  Handles meeting reminder trigger event.
  """
  @spec reminder_triggered(term()) :: {:ok, atom()}
  def reminder_triggered(_meeting) do
    # This would be called by the reminder job
    # The actual email sending is handled by the EmailWorker
    {:ok, :reminder_processed}
  end

  @doc """
  Determines if an event should trigger notifications.
  """
  @spec should_trigger_notifications?(atom(), term()) :: boolean()
  def should_trigger_notifications?(event_type, meeting) do
    case event_type do
      :meeting_created ->
        meeting.status == "confirmed"

      :meeting_cancelled ->
        meeting.status == "cancelled"

      :meeting_rescheduled ->
        meeting.status == "confirmed"

      :reminder_triggered ->
        meeting.status == "confirmed" and
          meeting.reminder_email_sent == false

      _unknown_event ->
        false
    end
  end

  @doc """
  Gets event metadata for logging and tracking.
  """
  @spec get_event_metadata(atom(), term()) :: map()
  def get_event_metadata(event_type, meeting) do
    %{
      event_type: event_type,
      meeting_id: meeting.id,
      meeting_uid: meeting.uid,
      meeting_status: meeting.status,
      attendee_email: meeting.attendee_email,
      organizer_email: meeting.organizer_email,
      meeting_start: meeting.start_time,
      event_timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Validates that an event can be processed.
  """
  @spec validate_event(atom(), term()) :: :ok | {:error, String.t()}
  def validate_event(event_type, meeting) do
    cond do
      is_nil(meeting) ->
        {:error, "Meeting is required"}

      not should_trigger_notifications?(event_type, meeting) ->
        {:error, "Event should not trigger notifications"}

      true ->
        :ok
    end
  end
end
