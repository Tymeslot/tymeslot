defmodule Tymeslot.Meetings.CalendarEvents do
  @moduledoc """
  Async calendar event orchestration for meetings — creation and cancellation
  via Oban workers.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarEventScheduler
  alias Tymeslot.Notifications.Orchestrator

  @doc """
  Creates a calendar event asynchronously.

  Schedules calendar event creation through an Oban worker. Does not fail the
  broader meeting creation workflow if scheduling fails — errors are logged and
  `:ok` is returned regardless.
  """
  @spec create_calendar_event_async(Ecto.Schema.t()) :: :ok
  def create_calendar_event_async(meeting) do
    case CalendarEventScheduler.schedule_calendar_creation(meeting.id) do
      :ok ->
        Logger.info("Calendar event creation scheduled",
          meeting_id: meeting.id,
          uid: meeting.uid
        )

        :ok

      {:error, reason} ->
        Logger.warning("Failed to schedule calendar event creation",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  @doc """
  Cancels the calendar event associated with a meeting.

  Schedules calendar event deletion through an Oban worker. Does not fail the
  broader cancellation workflow if scheduling fails — errors are logged and
  `:ok` is returned regardless.
  """
  @spec cancel_calendar_event(Ecto.Schema.t()) :: :ok
  def cancel_calendar_event(meeting) do
    Logger.info("Scheduling calendar event cancellation",
      meeting_id: meeting.id,
      uid: meeting.uid
    )

    case CalendarEventScheduler.schedule_calendar_deletion(meeting.id) do
      {:ok, _job} ->
        Logger.info("Calendar event deletion scheduled successfully",
          meeting_id: meeting.id,
          uid: meeting.uid
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule calendar event deletion",
          meeting_id: meeting.id,
          uid: meeting.uid,
          reason: inspect(reason)
        )

        :ok
    end
  rescue
    error ->
      Logger.warning("Exception while scheduling calendar event cancellation",
        meeting_id: meeting.id,
        error: inspect(error)
      )

      :ok
  end

  @doc """
  Schedules email notifications for a meeting via Oban.
  """
  @spec schedule_email_notifications(Ecto.Schema.t()) :: :ok | {:error, any()}
  def schedule_email_notifications(meeting) do
    case Orchestrator.schedule_meeting_notifications(meeting) do
      {:ok, _result} ->
        Logger.info("Meeting notifications scheduled", meeting_id: meeting.id)

      {:error, reason} ->
        Logger.warning("Failed to schedule meeting notifications",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )
    end
  end
end
