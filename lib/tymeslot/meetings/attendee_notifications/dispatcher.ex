defmodule Tymeslot.Meetings.AttendeeNotifications.Dispatcher do
  @moduledoc """
  Owns the Oban enqueue / replace / cancel logic for debounced attendee
  notifications.

  The only module in the codebase permitted to enqueue
  `Tymeslot.Meetings.AttendeeNotifications.Worker` jobs. Every call site that
  wants to notify attendees of a change or a deletion goes through
  `schedule_update/2` or `schedule_delete/2`; repeated calls within the
  debounce window replace the scheduled job's `scheduled_at` so a burst of
  edits collapses into one notification per event per action.

  ## Semantics

    * `schedule_update(event_id, kind)` — enqueue (or replace) an `:update`
      job scheduled `@debounce_seconds` in the future.
    * `schedule_delete(event_id, kind)` — enqueue (or replace) a `:delete`
      job scheduled `@debounce_seconds` in the future. Coexists with any
      pending `:update` job for the same event as an independent job.
    * `cancel_pending/2` — delete any scheduled/available Worker jobs for the
      given event + kind (both actions).
    * `pending?/2` — whether any scheduled/available Worker job exists for
      the given event + kind.

  Uniqueness is keyed on `{event_id, kind, action}`. Direct `Repo.*` calls for
  job lookup/delete live in `DispatcherQueries` to respect the project's
  `RepoCallBoundary` check.
  """

  alias Tymeslot.Meetings.AttendeeNotifications.DispatcherQueries
  alias Tymeslot.Meetings.AttendeeNotifications.Worker

  @debounce_seconds 120

  @type event_kind :: :meeting | :provider_calendar_event
  @type action :: :update | :delete

  @spec schedule_update(integer, event_kind) :: :ok
  def schedule_update(event_id, kind), do: enqueue(event_id, kind, :update)

  @spec schedule_delete(integer, event_kind) :: :ok
  def schedule_delete(event_id, kind), do: enqueue(event_id, kind, :delete)

  @spec cancel_pending(integer, event_kind) :: :ok
  def cancel_pending(event_id, kind) when is_integer(event_id) do
    _count = DispatcherQueries.delete_pending(event_id, Atom.to_string(kind))
    :ok
  end

  @spec pending?(integer, event_kind) :: boolean
  def pending?(event_id, kind) when is_integer(event_id) do
    DispatcherQueries.pending?(event_id, Atom.to_string(kind))
  end

  @spec enqueue(integer, event_kind, action) :: :ok
  defp enqueue(event_id, kind, action) when is_integer(event_id) do
    args = %{
      "event_id" => event_id,
      "kind" => Atom.to_string(kind),
      "action" => Atom.to_string(action)
    }

    {:ok, _job} =
      args
      |> Worker.new(
        schedule_in: @debounce_seconds,
        unique: [
          period: :infinity,
          states: [:available, :scheduled],
          keys: [:event_id, :kind, :action]
        ],
        replace: [scheduled: [:scheduled_at]]
      )
      |> Oban.insert()

    :ok
  end
end
