defmodule Tymeslot.Meetings.AttendeeNotifications.DispatcherQueries do
  @moduledoc """
  Ecto queries for the `Oban.Job` table backing
  `Tymeslot.Meetings.AttendeeNotifications.Dispatcher`.

  Exists solely to keep direct `Repo.*` calls out of the Dispatcher module — the
  project's `CredoChecks.RepoCallBoundary` restricts query execution to
  `*_queries.ex` / `*_schema.ex` files.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Repo

  @worker "Tymeslot.Meetings.AttendeeNotifications.Worker"
  @active_states ~w(available scheduled)

  @doc """
  Deletes any scheduled/available Worker jobs for the given `event_id` + `kind`.
  Returns the number of deleted rows.
  """
  @spec delete_pending(integer, binary) :: non_neg_integer
  def delete_pending(event_id, kind) when is_integer(event_id) and is_binary(kind) do
    event_id_str = Integer.to_string(event_id)

    {count, _rows} =
      Oban.Job
      |> where([j], j.worker == ^@worker)
      |> where([j], j.state in ^@active_states)
      |> where([j], fragment("?->>'event_id' = ?", j.args, ^event_id_str))
      |> where([j], fragment("?->>'kind' = ?", j.args, ^kind))
      |> Repo.delete_all()

    count
  end

  @doc """
  When the earliest scheduled/available Worker job for the given `event_id` +
  `kind` is due, or nil when none is waiting.
  """
  @spec pending_due_at(integer, binary) :: DateTime.t() | nil
  def pending_due_at(event_id, kind) when is_integer(event_id) and is_binary(kind) do
    event_id_str = Integer.to_string(event_id)

    Oban.Job
    |> where([j], j.worker == ^@worker)
    |> where([j], j.state in ^@active_states)
    |> where([j], fragment("?->>'event_id' = ?", j.args, ^event_id_str))
    |> where([j], fragment("?->>'kind' = ?", j.args, ^kind))
    |> select([j], min(j.scheduled_at))
    |> Repo.one()
  end

  @doc """
  Returns true if a Worker job for the given `event_id` + `kind`, scheduled
  for `due_at` or later, has started sending (it is running, has run or is
  retrying).
  """
  @spec sent_for?(integer, binary, DateTime.t()) :: boolean
  def sent_for?(event_id, kind, %DateTime{} = due_at)
      when is_integer(event_id) and is_binary(kind) do
    event_id_str = Integer.to_string(event_id)

    Oban.Job
    |> where([j], j.worker == ^@worker)
    |> where([j], j.state in ~w(executing completed retryable))
    |> where([j], j.scheduled_at >= ^due_at)
    |> where([j], fragment("?->>'event_id' = ?", j.args, ^event_id_str))
    |> where([j], fragment("?->>'kind' = ?", j.args, ^kind))
    |> Repo.exists?()
  end

  @doc """
  Returns true if a scheduled/available Worker job exists for the given
  `event_id` + `kind`.
  """
  @spec pending?(integer, binary) :: boolean
  def pending?(event_id, kind) when is_integer(event_id) and is_binary(kind) do
    event_id_str = Integer.to_string(event_id)

    Oban.Job
    |> where([j], j.worker == ^@worker)
    |> where([j], j.state in ^@active_states)
    |> where([j], fragment("?->>'event_id' = ?", j.args, ^event_id_str))
    |> where([j], fragment("?->>'kind' = ?", j.args, ^kind))
    |> Repo.exists?()
  end
end
