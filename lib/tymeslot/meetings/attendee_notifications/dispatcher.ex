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
    * `cancel_pending/3` — delete any scheduled/available Worker jobs for the
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

  @doc """
  Deletes the waiting jobs for the event + kind, for the hold the caller
  knew was due at `due_at` (`pending_due_at/2`): `{:ok, :cancelled}` when
  there was one. When nothing was waiting, `{:ok, :sent}` if that hold has
  started sending, else `{:ok, :none}` (cancelled elsewhere, say).

  A job belongs to the hold when it is scheduled for `due_at` or later (a
  later Tell, or a retry, only ever moves it later). An update sent before
  the hold began was due earlier, so it does not count: the guests were not
  told about what the hold was for.
  """
  @spec cancel_pending(integer, event_kind, DateTime.t()) ::
          {:ok, :cancelled | :sent | :none}
  def cancel_pending(event_id, kind, %DateTime{} = due_at) when is_integer(event_id) do
    kind = Atom.to_string(kind)

    cond do
      DispatcherQueries.delete_pending(event_id, kind) > 0 -> {:ok, :cancelled}
      DispatcherQueries.sent_for?(event_id, kind, due_at) -> {:ok, :sent}
      true -> {:ok, :none}
    end
  end

  @doc "When the waiting job for the event + kind is due, or nil when none is waiting."
  @spec pending_due_at(integer, event_kind) :: DateTime.t() | nil
  def pending_due_at(event_id, kind) when is_integer(event_id),
    do: DispatcherQueries.pending_due_at(event_id, Atom.to_string(kind))

  @spec pending?(integer, event_kind) :: boolean
  def pending?(event_id, kind) when is_integer(event_id) do
    DispatcherQueries.pending?(event_id, Atom.to_string(kind))
  end
end
