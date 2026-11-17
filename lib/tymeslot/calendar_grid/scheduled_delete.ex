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

  A rate-limited or circuit-open delete snoozes instead of failing, and both
  kinds of snooze count towards one cap of five snoozes, after which the
  delete is reported as failed. A provider that says the event is already
  gone counts as deleted, once its cached row (or, for a series delete, the
  series' rows) has been purged.
  """

  require Logger

  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.CalendarGrid.EventDeletion
  alias Tymeslot.CalendarGrid.Occurrence
  alias Tymeslot.CalendarGrid.ScheduledDeleteQueries
  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.SyncBroadcast
  alias Tymeslot.Workers.CalendarEventDeleteWorker

  @undo_delay 12
  @default_snooze 60

  @max_snoozes 5

  # The failures that may pass on their own, as the providers report them: a
  # request or the connection timing out, a server failing or refusing for the
  # moment (`{:http_error, status}` is the CalDAV shape for a status it has no
  # name for). Everything else is a refusal or a missing address, and says the
  # same thing next time.
  @transient [:timeout, :network_error, :server_error, :service_unavailable]

  # What addresses an event for `EventDeletion`.
  @address_fields [
    :uid,
    :provider,
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
  `delay` (seconds, default `undo_delay/0`), `notify_attendees`
  (default `false`) and `tab` (the browser tab that asked, kept with the
  job so only that tab offers Undo again after a reload; see `pending/1`).
  """
  @spec schedule(pos_integer(), map(), EventDeletion.scope(), keyword()) ::
          {:ok, token()} | {:error, term()}
  def schedule(user_id, event, scope, opts \\ []) when scope in [:occurrence, :series] do
    delay = Keyword.get(opts, :delay, @undo_delay)

    args =
      event
      |> Map.take(@address_fields)
      |> Map.merge(%{
        user_id: user_id,
        scope: scope,
        notify_attendees: Keyword.get(opts, :notify_attendees, false),
        undoable: delay > 0,
        tab: Keyword.get(opts, :tab)
      })

    case args |> CalendarEventDeleteWorker.new(schedule_in: delay) |> Oban.insert() do
      {:ok, %Oban.Job{id: id}} ->
        SyncBroadcast.broadcast_delete_scheduled(
          user_id,
          id,
          Map.take(event, @address_fields),
          scope
        )

        {:ok, id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Cancels the delete `token` of `user_id` if it has not started, and tells
  the organiser's other calendars. `{:error, :cancelled}` when it was already
  cancelled (from another tab), `{:error, :too_late}` when it is running, has
  run, or is not the organiser's.
  """
  @spec cancel(pos_integer(), token()) :: :ok | {:error, :cancelled | :too_late}
  def cancel(user_id, token) do
    if ScheduledDeleteQueries.cancel_waiting(token, user_id) do
      SyncBroadcast.broadcast_delete_cancelled(user_id, token)
    else
      case ScheduledDeleteQueries.state(token, user_id) do
        "cancelled" -> {:error, :cancelled}
        _running_done_or_unknown -> {:error, :too_late}
      end
    end
  end

  @doc """
  The user's deletes that are still waiting, running or retrying, for a
  surface to hide their events and offer Undo again after a reload. Each entry
  carries the `token` Undo takes, the address the delete was scheduled with,
  its `scope`, when it is due and the `tab` that scheduled it (`nil` when
  none was named, as for a job stored before tabs were). `undoable?` is false for a delete that was
  confirmed (it tells someone, so it was scheduled with no undo window) and
  while a job is running or retrying. A silent delete a rate limit snoozed
  is back in `scheduled` and still undoable, which is harmless: nothing has
  reached the calendar yet.
  """
  @spec pending(pos_integer()) :: [map()]
  def pending(user_id) do
    user_id
    |> ScheduledDeleteQueries.waiting()
    |> Enum.map(fn %Oban.Job{id: id, args: args, scheduled_at: scheduled_at, state: state} ->
      args
      |> event_from()
      |> Map.merge(%{
        token: id,
        scope: scope(args),
        scheduled_at: scheduled_at,
        tab: Map.get(args, "tab"),
        undoable?: Map.get(args, "undoable") != false and state in ["scheduled", "available"]
      })
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
    case run(user_id, args) do
      {:snooze, reason, seconds} ->
        snooze_or_give_up(job, reason, seconds)

      {:retry, reason} when job.attempt < job.max_attempts ->
        {:error, reason}

      {:retry, reason} ->
        report(user_id, token, args, {:failed, reason})

      outcome ->
        report(user_id, token, args, outcome)
    end
  end

  # Oban counts each snooze in `meta["snoozed"]`.
  defp snooze_or_give_up(%Oban.Job{id: token, args: args, meta: meta}, reason, seconds) do
    if Map.get(meta, "snoozed", 0) >= @max_snoozes,
      do: report(args["user_id"], token, args, {:failed, reason}),
      else: {:snooze, seconds}
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

  defp run(user_id, args) do
    event = event_from(args)

    if still_cached?(event, scope(args)) do
      delete(user_id, event, args)
    else
      # The sync (or an earlier attempt) already removed it.
      :deleted
    end
  rescue
    error ->
      Logger.error("Scheduled calendar delete crashed",
        user_id: user_id,
        error: LogFormat.reason(error)
      )

      {:failed, :crashed}
  end

  # A series delete goes by the series' address, so it still has work to do
  # while any row of the series is cached, whichever occurrence was clicked.
  defp still_cached?(event, :series) do
    case Occurrence.series_address(event) do
      {:ok, address} ->
        ScheduledDeleteQueries.series_row_exists?(event.calendar_integration_id, address)

      {:error, _unaddressable} ->
        row_cached?(event)
    end
  end

  defp still_cached?(event, _occurrence), do: row_cached?(event)

  defp row_cached?(event),
    do:
      match?(
        {:ok, _row},
        ProviderCalendarEventQueries.get_by_uid(event.calendar_integration_id, event.uid)
      )

  defp delete(user_id, event, args) do
    notify? = args["notify_attendees"] == true

    with :ok <- EditGuard.seat_lock(user_id, event),
         {:ok, _deleted} <-
           EventDeletion.delete_event(user_id, event, scope(args), notify_attendees: notify?) do
      :deleted
    else
      {:error, :group_booking} ->
        {:failed, :group_booking}

      # The calendar says it is gone already; the cached row has to follow it
      # or the event would reappear until the next sync.
      {:error, %{reason: :not_found, retry: retry}} when retry != :queued ->
        purge_cached(event, scope(args))
        :deleted

      {:error, %{reason: reason, retry: retry}} ->
        classify(reason, retry, event)
    end
  end

  defp purge_cached(event, :series) do
    case Occurrence.series_address(event) do
      {:ok, address} -> EventDeletion.delete_series_rows(event.calendar_integration_id, address)
      {:error, _unaddressable} -> purge_row(event)
    end
  end

  defp purge_cached(event, _occurrence), do: purge_row(event)

  defp purge_row(event),
    do: ProviderCalendarEventQueries.delete_by_uid(event.calendar_integration_id, event.uid)

  defp classify(reason, :queued, _event), do: {:queued, reason}

  defp classify({:rate_limited, seconds}, _retry, _event),
    do: {:snooze, :rate_limited, snooze(seconds)}

  defp classify(:rate_limited, _retry, _event), do: {:snooze, :rate_limited, snooze(nil)}

  defp classify(:circuit_open, _retry, event),
    do: {:snooze, :circuit_open, breaker_recovery(event)}

  defp classify(reason, :not_queued, _event) do
    if transient?(reason), do: {:retry, reason}, else: {:failed, reason}
  end

  # The breaker lets a probe through once its recovery time has passed.
  defp breaker_recovery(event) do
    case ProviderConfig.parse_known(Map.get(event, :provider)) do
      {:ok, provider} ->
        provider
        |> CalendarCircuitBreaker.get_config()
        |> Map.fetch!(:recovery_timeout)
        |> div(1000)
        |> max(1)

      _unknown ->
        @default_snooze
    end
  end

  defp snooze(seconds) when is_integer(seconds) and seconds > 0, do: seconds
  defp snooze(_other), do: @default_snooze

  defp transient?(reason) when reason in @transient, do: true
  defp transient?({:http_error, status}) when is_integer(status), do: status >= 500
  defp transient?(_reason), do: false

  defp event_from(args),
    do: Map.new(@address_fields, &{&1, Map.get(args, Atom.to_string(&1))})

  defp scope(%{"scope" => "series"}), do: :series
  defp scope(_args), do: :occurrence
end
