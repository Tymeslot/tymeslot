defmodule Tymeslot.Bookings.CalendarJobs do
  @moduledoc """
  Shared calendar event job scheduling for bookings.

  This module provides a single interface for scheduling calendar event worker jobs
  for both meeting creation and rescheduling operations, reducing duplication and
  ensuring consistent handling across the codebase.
  """

  alias Tymeslot.Workers.CalendarEventWorker

  @doc """
  Schedules a calendar event job for a meeting.

  Handles both creation and update actions with appropriate priority levels.
  Treats duplicate job scheduling (unique constraint) as a non-error success case.

  ## Parameters
  - meeting: The meeting struct containing the ID
  - action: The action to perform, either "create" or "update"

  ## Returns
  - {:ok, :scheduled} if the job was successfully created
  - {:ok, :already_scheduled} if a job with the same parameters already exists
  - {:error, changeset} if job insertion fails for other reasons
  """
  @spec schedule_job(map(), String.t()) :: {:ok, atom()} | {:error, any()}
  def schedule_job(meeting, action) when is_binary(action) do
    priority = priority_for_action(action)

    job_changeset =
      CalendarEventWorker.new(
        %{"action" => action, "meeting_id" => meeting.id},
        queue: :calendar_events,
        priority: priority,
        unique: [
          period: 300,
          fields: [:args, :queue],
          keys: [:action, :meeting_id],
          states: [:available, :scheduled, :executing]
        ]
      )

    case Oban.insert(job_changeset) do
      {:ok, _job} -> {:ok, :scheduled}
      {:error, %Ecto.Changeset{errors: [unique: _]}} -> {:ok, :already_scheduled}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Returns the appropriate Oban job priority for the given action.

  - "create" actions have priority 0 (higher priority)
  - "update" actions have priority 2 (lower priority)
  """
  @spec priority_for_action(String.t()) :: integer()
  def priority_for_action("create"), do: 0
  def priority_for_action("update"), do: 2
  def priority_for_action(_), do: 1
end
