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

  When it runs (`perform/2`) the seat lock is checked again, the event is
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
  alias Tymeslot.Integrations.Calendar.SyncBroadcast
  alias Tymeslot.Workers.CalendarEventDeleteWorker

  @undo_delay 12

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

  @doc "Runs the delete `token` its job describes, and broadcasts the outcome."
  @spec perform(token(), map()) :: :ok
  def perform(token, %{"user_id" => user_id} = args) do
    SyncBroadcast.broadcast_delete_result(user_id, token, run(user_id, args))
  end

  defp run(user_id, args) do
    event = event_from(args)
    notify? = args["notify_attendees"] == true

    with :ok <- EditGuard.seat_lock(user_id, event),
         {:ok, _deleted} <-
           EventDeletion.delete_event(user_id, event, scope(args), notify_attendees: notify?) do
      :deleted
    else
      {:error, :group_booking} -> {:failed, :group_booking}
      {:error, %{retry: :queued, reason: reason}} -> {:queued, reason}
      {:error, %{reason: reason}} -> {:failed, reason}
    end
  rescue
    error ->
      Logger.error("Scheduled calendar delete crashed",
        user_id: user_id,
        error: LogFormat.reason(error)
      )

      {:failed, :crashed}
  end

  defp event_from(args),
    do: Map.new(@address_fields, &{&1, Map.get(args, Atom.to_string(&1))})

  defp scope(%{"scope" => "series"}), do: :series
  defp scope(_args), do: :occurrence
end
