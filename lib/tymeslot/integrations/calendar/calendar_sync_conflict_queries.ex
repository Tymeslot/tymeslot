defmodule Tymeslot.Integrations.Calendar.CalendarSyncConflictQueries do
  @moduledoc """
  Data access for `calendar_sync_conflicts`. All `Repo` calls for the conflict
  audit live here (RepoCallBoundary).

  Append and read, and nothing else. The table is an audit: an update or a
  delete exposed here would let a later resolution rewrite the record of an
  earlier one, which is precisely the history the table exists to keep. Bounded
  growth is pruning's job, on the `DataRetentionWorker` pattern, not
  a caller's.
  """
  import Ecto.Query

  alias Tymeslot.Integrations.Calendar.CalendarSyncConflictSchema
  alias Tymeslot.Repo

  @default_limit 50

  @doc """
  Records one resolved divergence.

  `:occurred_at` may be omitted when the divergence is being recorded as it
  happens; the schema stamps it. A reconciliation sweep, which discovers a
  divergence some time after the fact, should pass the time it actually
  occurred.
  """
  @spec append(map()) ::
          {:ok, CalendarSyncConflictSchema.t()} | {:error, Ecto.Changeset.t()}
  def append(attrs) do
    %CalendarSyncConflictSchema{}
    |> CalendarSyncConflictSchema.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  One link's conflict history, newest first.

  Ordered and capped rather than returned whole: the dashboard shows a recent
  window, and an append-only table under a busy link has no upper bound worth
  loading into a socket assign. `:limit` overrides the default of
  #{@default_limit}.

  Ties on `occurred_at` break by id descending. A sweep recording several
  divergences in one pass can stamp them with the same instant, and without the
  tiebreak their order would be whatever the planner chose that run — so the
  list would reshuffle between two renders of unchanged data.
  """
  @spec list_for_link(integer(), keyword()) :: [CalendarSyncConflictSchema.t()]
  def list_for_link(sync_link_id, opts \\ []) when is_integer(sync_link_id) do
    limit = Keyword.get(opts, :limit, @default_limit)

    CalendarSyncConflictSchema
    |> where([c], c.sync_link_id == ^sync_link_id)
    |> order_by([c], desc: c.occurred_at, desc: c.id)
    |> limit(^limit)
    |> Repo.all()
  end
end
