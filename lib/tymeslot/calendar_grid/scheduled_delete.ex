defmodule Tymeslot.CalendarGrid.ScheduledDelete do
  @moduledoc """
  Deletes made from the calendar, run once their undo window has passed.

  `schedule/4` stores a delete as a `Tymeslot.Workers.CalendarEventDeleteWorker`
  job due `undo_delay/0` seconds later (or at once, `delay: 0`, for a delete
  the organiser confirmed because it tells someone) and answers the job's id
  as the delete's token. The calendar hides the event meanwhile. Undo is
  `cancel/2`, which cancels the job only while it is still waiting, so a
  delete is either cancelled before anything reaches the calendar or run,
  never both. A job outlives the tab that scheduled it, so closing the tab
  inside the window still deletes the event.

  The job deletes what the cached row says when it runs, so an edit made in
  another tab during the window is deleted too.

  When it runs (`perform/1`) the seat lock is checked again, the event is
  deleted through `EventDeletion.delete_event/4`, and the outcome is
  broadcast on the organiser's calendar topic as
  `{:calendar_delete_result, user_id, token, outcome}`: `:deleted`,
  `{:queued, reason}` when the delete will be replayed on the next sync, or
  `{:failed, reason}`.
  """

  require Logger

  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.CalendarGrid.EventDeletion
  alias Tymeslot.CalendarGrid.ScheduledDeleteQueries
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.SyncBroadcast
  alias Tymeslot.Workers.CalendarEventDeleteWorker

  @undo_delay 12
  @default_snooze 60

  @permanent [:recurring_event, :unaddressable_occurrence, :unaddressable_series]

  # What addresses an event for `EventDeletion` (see
  # `NotificationFlows.build_delete_payload/4` in the old grid).
  @address_fields [
    :uid,
    :calendar_integration_id,
    :provider_event_id,
    :provider_calendar_id,
    :recurring_event_id,
    :recurrence_rule
  ]

  @type token :: pos_integer()
  @type outcome :: :deleted | {:queued, term()} | {:failed, term()}

  @doc "Seconds between a delete and its run, while Undo can cancel it."
  @spec undo_delay() :: pos_integer()
  def undo_delay, do: @undo_delay

  @doc """
  Schedules the delete of `event` in `scope` for `user_id`. Options:
  `delay` (seconds, default `undo_delay/0`) and `notify_attendees`
  (default `false`).
  """
  @spec schedule(pos_integer(), map(), EventDeletion.scope(), keyword()) ::
          {:ok, token()} | {:error, term()}
  def schedule(user_id, event, scope, opts \\ []) when scope in [:occurrence, :series] do
    args =
      event
      |> Map.take(@address_fields)
      |> Map.merge(%{
        user_id: user_id,
        scope: scope,
        notify_attendees: Keyword.get(opts, :notify_attendees, false)
      })

    case args
         |> CalendarEventDeleteWorker.new(schedule_in: Keyword.get(opts, :delay, @undo_delay))
         |> Oban.insert() do
      {:ok, %Oban.Job{id: id}} -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Cancels the delete `token` of `user_id` if it has not started."
  @spec cancel(pos_integer(), token()) :: :ok | {:error, :too_late}
  def cancel(user_id, token) do
    if ScheduledDeleteQueries.cancel_waiting(token, user_id), do: :ok, else: {:error, :too_late}
  end

  @doc """
  The user's deletes that are still waiting or running, for a surface to hide
  their events and offer Undo again after a reload. Each entry carries the
  `token` Undo takes, the address the delete was scheduled with, its `scope`
  and when it is due.
  """
  @spec pending(pos_integer()) :: [map()]
  def pending(user_id) do
    user_id
    |> ScheduledDeleteQueries.waiting()
    |> Enum.map(fn %Oban.Job{id: id, args: args, scheduled_at: scheduled_at} ->
      args
      |> event_from()
      |> Map.merge(%{token: id, scope: scope(args), scheduled_at: scheduled_at})
    end)
  end

  @doc """
  Runs the delete its job describes and broadcasts the outcome. A rate-limited
  delete snoozes. A failure the delete was not queued for and that may pass
  (a timeout, a server error) is retried by Oban, and reported only on the
  last attempt; every other outcome is reported at once. A failure is always
  logged.
  """
  @spec perform(Oban.Job.t()) :: :ok | {:snooze, pos_integer()} | {:error, term()}
  def perform(%Oban.Job{id: token, args: %{"user_id" => user_id} = args} = job) do
    case run(user_id, args, job.attempt > 1) do
      {:snooze, seconds} ->
        {:snooze, seconds}

      {:retry, reason} when job.attempt < job.max_attempts ->
        {:error, reason}

      {:retry, reason} ->
        report(user_id, token, args, {:failed, reason})

      outcome ->
        report(user_id, token, args, outcome)
    end
  end

  defp report(user_id, token, args, outcome) do
    with {:failed, reason} <- outcome do
      Logger.warning("Scheduled calendar delete failed",
        user_id: user_id,
        calendar_integration_id: args["calendar_integration_id"],
        reason: LogFormat.reason(reason)
      )
    end

    SyncBroadcast.broadcast_delete_result(user_id, token, outcome)
    :ok
  end

  defp run(user_id, args, retrying?) do
    event = event_from(args)

    case ProviderCalendarEventQueries.get_by_uid(event.calendar_integration_id, event.uid) do
      {:ok, _row} -> delete(user_id, event, args, retrying?)
      # The sync (or an earlier attempt) already removed it.
      {:error, :not_found} -> :deleted
    end
  rescue
    error ->
      Logger.error("Scheduled calendar delete crashed",
        user_id: user_id,
        error: LogFormat.reason(error)
      )

      {:failed, :crashed}
  end

  defp delete(user_id, event, args, retrying?) do
    notify? = args["notify_attendees"] == true

    with :ok <- EditGuard.seat_lock(user_id, event),
         {:ok, _deleted} <-
           EventDeletion.delete_event(user_id, event, scope(args), notify_attendees: notify?) do
      :deleted
    else
      {:error, :group_booking} -> {:failed, :group_booking}
      {:error, %{reason: reason, retry: retry}} -> classify(reason, retry, retrying?)
    end
  end

  defp classify(reason, :queued, _retrying?), do: {:queued, reason}
  defp classify({:rate_limited, seconds}, _retry, _retrying?), do: {:snooze, snooze(seconds)}
  defp classify(:rate_limited, _retry, _retrying?), do: {:snooze, snooze(nil)}
  defp classify(:not_found, _retry, true), do: :deleted

  defp classify(reason, :not_queued, _retrying?) do
    if transient?(reason), do: {:retry, reason}, else: {:failed, reason}
  end

  defp snooze(seconds) when is_integer(seconds) and seconds > 0, do: seconds
  defp snooze(_other), do: @default_snooze

  # A failure the calendar might not repeat: not a refusal, a missing event or
  # an address the cached row cannot give, and not something the delete would
  # have been queued for the next sync to replay (that is `:queued`).
  defp transient?(reason),
    do: reason not in @permanent and CalendarEvents.queueable_error?(reason)

  defp event_from(args),
    do: Map.new(@address_fields, &{&1, Map.get(args, Atom.to_string(&1))})

  defp scope(%{"scope" => "series"}), do: :series
  defp scope(_args), do: :occurrence
end
