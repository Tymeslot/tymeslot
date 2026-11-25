defmodule Tymeslot.Meetings.CalendarEvents do
  @moduledoc """
  Async calendar event orchestration for meetings: cancellation via Oban
  workers.
  """

  require Logger

  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Integrations.Calendar.CalendarEventScheduler
  alias Tymeslot.Meetings.CalendarEventMapping

  @doc """
  Cancels the calendar event associated with a meeting.

  Schedules calendar event deletion through an Oban worker. Does not fail the
  broader cancellation workflow if scheduling fails — errors are logged and
  `:ok` is returned regardless.
  """
  @spec cancel_calendar_event(Ecto.Schema.t()) :: :ok
  def cancel_calendar_event(meeting) do
    Logger.info("Scheduling calendar event cancellation",
      meeting_id: meeting.id
    )

    case CalendarEventScheduler.schedule_calendar_deletion(meeting.id) do
      {:ok, _job} ->
        Logger.info("Calendar event deletion scheduled successfully",
          meeting_id: meeting.id
        )

        :ok

      {:error, reason} ->
        ErrorTracking.report_error(reason, nil, %{meeting_id: meeting.id})
    end
  rescue
    error ->
      ErrorTracking.report_error(error, __STACKTRACE__, %{meeting_id: meeting.id})
  end

  @doc """
  Deletes the calendar event of a meeting that is about to stop carrying it.

  Pass the meeting as it was *before* its event mapping was cleared: the
  event's identifier is copied into the job, since the meeting will not name
  it when the job runs. The job is a replacement of an event the meeting no
  longer carries, which only deletes it
  (`Tymeslot.Meetings.CalendarEventSync.replace/3`), whatever the meeting has
  become by then; its calendar is the one the meeting still names. A meeting
  with no calendar integration has no event to delete. Like
  `cancel_calendar_event/1`, a failure to schedule is reported, never raised.
  """
  @spec release_calendar_event(Ecto.Schema.t()) :: :ok
  def release_calendar_event(%{calendar_integration_id: nil}), do: :ok

  def release_calendar_event(meeting) do
    case CalendarEventMapping.event_identifier(meeting) do
      event_id when is_binary(event_id) ->
        case CalendarEventScheduler.schedule_calendar_replacement(meeting.id, event_id) do
          {:ok, _job} -> :ok
          {:error, reason} -> ErrorTracking.report_error(reason, nil, %{meeting_id: meeting.id})
        end

      nil ->
        :ok
    end
  end
end
