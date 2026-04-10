defmodule Tymeslot.Integrations.Calendar.CalendarEventScheduler do
  @moduledoc """
  Schedules calendar event jobs via Oban.

  This module is the single point of entry for enqueueing calendar event
  creation, update, and deletion jobs. Each function constructs the
  appropriate Oban job via `Tymeslot.Workers.CalendarEventWorker.new/2`
  and inserts it into the database. Uniqueness constraints on each job
  type prevent duplicate operations within the configured windows.

  Callers should reference this module directly — no delegation functions
  exist on `Tymeslot.Workers.CalendarEventWorker`.
  """

  alias Ecto.Changeset
  alias Tymeslot.Workers.CalendarEventWorker

  require Logger

  @doc """
  Schedules calendar event creation to happen asynchronously with high priority.
  """
  @spec schedule_calendar_creation(integer()) :: :ok | {:error, String.t()}
  def schedule_calendar_creation(meeting_id) do
    result =
      %{"action" => "create", "meeting_id" => meeting_id}
      |> CalendarEventWorker.new(
        queue: :calendar_events,
        # Highest priority for calendar sync
        priority: 0,
        unique: [
          # 5 minutes uniqueness window
          period: 300,
          fields: [:args, :queue],
          keys: [:action, :meeting_id],
          states: [:available, :scheduled, :executing, :retryable]
        ]
      )
      |> Oban.insert()

    case result do
      {:ok, _job} ->
        Logger.info("Calendar event creation job scheduled", meeting_id: meeting_id)
        :ok

      {:error, %Changeset{errors: [unique: _details]}} ->
        Logger.info("Calendar event creation job already exists, skipping duplicate",
          meeting_id: meeting_id
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule calendar event creation",
          meeting_id: meeting_id,
          error: format_insert_error(reason)
        )

        {:error, "Failed to schedule job"}
    end
  end

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

  # Private helpers

  defp format_insert_error(%Changeset{} = changeset) do
    Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end

  defp format_insert_error(other), do: inspect(other)
end
