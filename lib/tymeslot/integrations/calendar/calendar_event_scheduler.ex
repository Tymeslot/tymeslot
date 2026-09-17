defmodule Tymeslot.Integrations.Calendar.CalendarEventScheduler do
  @moduledoc """
  Schedules calendar event jobs via Oban.

  Enqueues calendar event update and deletion jobs. Creation jobs are
  enqueued by `Tymeslot.Bookings.CalendarJobs.schedule_job/2` instead. Each
  function constructs the appropriate Oban job via
  `Tymeslot.Workers.CalendarEventWorker.new/2` and inserts it into the
  database. Uniqueness constraints on each job
  type prevent duplicate operations within the configured windows.

  Callers should reference this module directly — no delegation functions
  exist on `Tymeslot.Workers.CalendarEventWorker`.
  """

  alias Tymeslot.Workers.CalendarEventWorker

  @doc """
  Schedules calendar event update with medium priority.
  """
  @spec schedule_calendar_update(String.t() | integer()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def schedule_calendar_update(meeting_id) do
    %{"action" => "update", "meeting_id" => meeting_id}
    |> CalendarEventWorker.new(
      queue: :calendar_events,
      # Medium priority for updates
      priority: 2,
      unique: [
        period: 300,
        fields: [:args, :queue],
        keys: [:action, :meeting_id],
        states: [:available, :scheduled, :executing, :retryable]
      ]
    )
    |> Oban.insert()
  end

  @doc """
  Schedules calendar event deletion with high priority.
  """
  @spec schedule_calendar_deletion(String.t() | integer()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def schedule_calendar_deletion(meeting_id) do
    %{"action" => "delete", "meeting_id" => meeting_id}
    |> CalendarEventWorker.new(
      queue: :calendar_events,
      # High priority for deletions
      priority: 1,
      unique: [
        period: 300,
        fields: [:args, :queue],
        keys: [:action, :meeting_id],
        states: [:available, :scheduled, :executing, :retryable]
      ]
    )
    |> Oban.insert()
  end
end
