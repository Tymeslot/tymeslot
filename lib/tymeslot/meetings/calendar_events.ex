defmodule Tymeslot.Meetings.CalendarEvents do
  @moduledoc """
  Async calendar event orchestration for meetings: cancellation via Oban
  workers.
  """

  require Logger

  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Integrations.Calendar.CalendarEventScheduler

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
end
