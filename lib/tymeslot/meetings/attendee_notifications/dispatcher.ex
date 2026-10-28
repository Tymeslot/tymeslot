defmodule Tymeslot.Meetings.AttendeeNotifications.Dispatcher do
  @moduledoc """
  Owns the Oban enqueue / replace / cancel logic for debounced attendee
  notifications.

  The only module in the codebase permitted to enqueue
  `Tymeslot.Meetings.AttendeeNotifications.Worker` jobs, and the
  `MembershipWorker` jobs that hold a change of who attends until a change
  saved to sync later has reached the calendar. Every call site that
  wants to notify attendees of a change goes through `schedule_update/2`;
  repeated calls within the debounce window replace the scheduled job's
  `scheduled_at` so a burst of edits collapses into one notification per
  event.

  Deletes are not debounced: the cancellation goes out as the delete
  succeeds, from the event as it was (see
  `AttendeeNotifications.event_deleted_confirm/3`), because once the event is
  deleted there is no row left for a delayed job to read.

  ## Semantics

    * `schedule_update(event_id, kind)` — enqueue (or replace) an `:update`
      job scheduled `@debounce_seconds` in the future.
    * `cancel_pending/2` — delete any scheduled/available Worker jobs for the
      given event + kind, including a legacy `:delete` job.
    * `pending?/2` — whether any scheduled/available Worker job exists for
      the given event + kind.

  Uniqueness is keyed on `{event_id, kind, action}`. Direct `Repo.*` calls for
  job lookup/delete live in `DispatcherQueries` to respect the project's
  `RepoCallBoundary` check.
  """

  alias Tymeslot.Meetings.AttendeeNotifications.DispatcherQueries
  alias Tymeslot.Meetings.AttendeeNotifications.MembershipWorker
  alias Tymeslot.Meetings.AttendeeNotifications.Worker

  @debounce_seconds 120

  @type event_kind :: :provider_calendar_event

  @spec schedule_update(integer, event_kind) :: {:ok, :scheduled} | {:error, term}
  def schedule_update(event_id, kind) when is_integer(event_id) do
    args = %{
      "event_id" => event_id,
      "kind" => Atom.to_string(kind),
      "action" => "update"
    }

    case args
         |> Worker.new(
           schedule_in: @debounce_seconds,
           unique: [
             period: :infinity,
             states: [:available, :scheduled],
             keys: [:event_id, :kind, :action]
           ],
           replace: [scheduled: [:scheduled_at]]
         )
         |> Oban.insert() do
      {:ok, _job} -> {:ok, :scheduled}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Holds the emails of a change of who attends the event `uid` of the
  integration `integration_id` until the change saved to sync later has
  reached the calendar (see `MembershipWorker`). `attendees_before` is who
  attended before it, and the invitations and cancellations are worked out
  from them and the event as the replay left it.

  One job per event: a later change saved before the replay joins the
  waiting job, which keeps the attendees from before the first, so that the
  emails tell the guests about every saved change at once.
  """
  @spec schedule_membership(integer, String.t(), [map], pos_integer) ::
          {:ok, :scheduled} | {:error, term}
  def schedule_membership(integration_id, uid, attendees_before, owner_user_id)
      when is_integer(integration_id) and is_binary(uid) do
    args = %{
      "calendar_integration_id" => integration_id,
      "uid" => uid,
      "attendees_before" => attendees_before,
      "owner_user_id" => owner_user_id
    }

    case args
         |> MembershipWorker.new(
           unique: [
             period: :infinity,
             states: [:available, :scheduled, :retryable],
             keys: [:calendar_integration_id, :uid]
           ]
         )
         |> Oban.insert() do
      {:ok, _job} -> {:ok, :scheduled}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec cancel_pending(integer, event_kind) :: :ok
  def cancel_pending(event_id, kind) when is_integer(event_id) do
    _count = DispatcherQueries.delete_pending(event_id, Atom.to_string(kind))
    :ok
  end

  @spec pending?(integer, event_kind) :: boolean
  def pending?(event_id, kind) when is_integer(event_id) do
    DispatcherQueries.pending?(event_id, Atom.to_string(kind))
  end
end
