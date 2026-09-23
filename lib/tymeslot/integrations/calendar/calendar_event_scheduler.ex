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

  # A job that is still waiting will read the meeting when it runs, so a second
  # one for the same work would only repeat it. A job that is already
  # *executing* has read it, and nothing it learns afterwards can reach the
  # event it is writing.
  #
  # For a create or a delete that costs nothing: the outcome does not depend on
  # what changed in between. An update carries the meeting's current state, so
  # collapsing one into a running job silently drops whatever prompted it. That
  # is how a video link goes missing from the host's calendar entry: approving a
  # booking enqueues an update, the video room is created moments later while
  # that update is still in flight, and the update `Meetings.VideoRooms` then
  # enqueues to carry the link is dropped as a duplicate of the one that has
  # already read the meeting without it.
  #
  # Enqueuing it is half the fix. `Workers.CalendarEventWorker` holds the new
  # job behind the one in flight, so the two do not write at once — the server
  # would refuse the second conditional PUT, and the write that carries the
  # link would be the one refused.
  @update_unique_states [:available, :scheduled, :retryable]
  @exclusive_unique_states [:available, :scheduled, :executing, :retryable]

  @doc """
  The Oban `unique` states a calendar job of `action` may be collapsed into.

  Exposed so `Tymeslot.Bookings.CalendarJobs.schedule_job/2`, which enqueues
  the same worker, cannot drift from the rule here.
  """
  @spec unique_states(String.t()) :: [atom()]
  def unique_states("update"), do: @update_unique_states
  def unique_states(_action), do: @exclusive_unique_states

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
        states: unique_states("update")
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
        states: unique_states("delete")
      ]
    )
    |> Oban.insert()
  end
end
