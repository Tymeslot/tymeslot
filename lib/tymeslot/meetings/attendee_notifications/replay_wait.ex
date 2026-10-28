defmodule Tymeslot.Meetings.AttendeeNotifications.ReplayWait do
  @moduledoc """
  Holds an attendee email back while the event's cached row carries a change
  the calendar has not yet accepted.

  A dashboard edit made while a CalDAV server could not be reached is saved
  on the row and replayed by `Tymeslot.Integrations.Calendar.CalDAV.OfflineQueue`
  on a later sync. Guests are told about it only once that replay has
  succeeded, which marks the row `"synced"`: an invitation to an event the
  calendar does not yet hold, or a cancellation while the guest is still on
  it, cannot be taken back if the change never lands.

  The jobs that send these emails check again every `@recheck_seconds`, a
  little more often than the fallback sync sweep runs. One still waiting
  `@give_up_after_days` days after it was enqueued gives up: the change has
  been stuck for so long that telling anyone now would be news about the
  past.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema

  @recheck_seconds 300
  @give_up_after_days 7

  @doc """
  Whether the cached row of `event`, known by its integration and uid, holds
  a change not yet replayed to the calendar. An event with no cached row, or
  one whose integration has no offline queue, is never waiting.

  Read from the table, never from `event`: the grid's copy of a row predates
  the write that queued it.
  """
  @spec awaiting_replay?(map()) :: boolean()
  def awaiting_replay?(%{calendar_integration_id: integration_id, uid: uid})
      when is_integer(integration_id) and is_binary(uid) do
    case ProviderCalendarEventQueries.get_by_uid(integration_id, uid) do
      {:ok, %ProviderCalendarEventSchema{sync_state: state}} -> state != "synced"
      {:error, :not_found} -> false
    end
  end

  def awaiting_replay?(_event), do: false

  @doc """
  What a job still waiting on a replay answers: `{:snooze, seconds}` to check
  again, or `:ok` once it has waited too long, logged so the dropped email
  can be traced.
  """
  @spec wait(Oban.Job.t()) :: {:snooze, pos_integer()} | :ok
  def wait(%Oban.Job{inserted_at: inserted_at} = job) do
    if DateTime.diff(DateTime.utc_now(), inserted_at, :day) < @give_up_after_days do
      {:snooze, @recheck_seconds}
    else
      Logger.warning("Attendee email dropped: the calendar change it describes never synced",
        worker: job.worker,
        job_id: job.id
      )

      :ok
    end
  end
end
