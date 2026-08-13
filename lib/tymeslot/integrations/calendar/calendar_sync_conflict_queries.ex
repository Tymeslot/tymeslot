defmodule Tymeslot.Integrations.Calendar.CalendarSyncConflictQueries do
  @moduledoc """
  Data access for `calendar_sync_conflicts`. All `Repo` calls for the conflict
  audit live here (RepoCallBoundary).

  Append and read, and — for retention alone — a bulk delete on age. The table
  is an audit: no caller may update a row or remove one by id, because that
  would let a later resolution rewrite the record of an earlier one, which is
  precisely the history the table exists to keep. `prune_older_than/1` is the
  single exception and is not a caller's to reach for: it is
  `DataRetentionWorker`'s, it names no row, and its only argument is an age.
  """
  import Ecto.Query

  alias Tymeslot.Infrastructure.BatchDeleteQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncConflictSchema
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema
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

  @doc """
  The recent history of several links at once, keyed by link id and newest
  first within each.

  The dashboard's read. One query for every link on the page rather than one per
  link: the panel renders an organiser's links together, and asking per row is
  the n+1 the link queries' preloads already exist to avoid.

  The cap is applied per link after grouping rather than in SQL. A per-link
  `LIMIT` needs a lateral join or a window function, and what it would save is
  not worth it here — the cap exists to bound what a socket assign holds, not
  what Postgres reads, and the rows are already narrowed to one organiser's
  links by the ids the caller passes.

  Links with no history are absent rather than present with an empty list, so a
  caller can render a section for exactly the keys it finds.
  """
  @spec list_for_links([integer()], keyword()) :: %{
          optional(integer()) => [CalendarSyncConflictSchema.t()]
        }
  def list_for_links(sync_link_ids, opts \\ [])

  def list_for_links([], _opts), do: %{}

  def list_for_links(sync_link_ids, opts) when is_list(sync_link_ids) do
    limit = Keyword.get(opts, :limit, @default_limit)

    CalendarSyncConflictSchema
    |> where([c], c.sync_link_id in ^sync_link_ids)
    |> order_by([c], desc: c.occurred_at, desc: c.id)
    |> Repo.all()
    |> Enum.group_by(& &1.sync_link_id)
    |> Map.new(fn {sync_link_id, conflicts} -> {sync_link_id, Enum.take(conflicts, limit)} end)
  end

  @doc """
  Every link id belonging to one organiser.

  Lives here rather than in `CalendarSyncLinkQueries` because it exists for one
  caller — the conflict read, which needs the set of links it is allowed to
  answer for and nothing else about them. `list_for_user/1` there returns whole
  rows with both integrations preloaded, which is the wrong shape and two joins
  too many for a question whose answer is a list of integers.
  """
  @spec link_ids_for_user(integer()) :: [integer()]
  def link_ids_for_user(user_id) when is_integer(user_id) do
    CalendarSyncLinkSchema
    |> where([l], l.user_id == ^user_id)
    |> select([l], l.id)
    |> Repo.all()
  end

  @doc """
  Drops conflicts older than `days`, in bounded batches.

  Cut on `occurred_at`, not `inserted_at`. A reconciliation sweep discovers a
  divergence some time after it happened and stamps the real time, so the two
  columns can be months apart — and pruning on insertion would keep a
  year-old conflict alive for a further retention window purely because a sweep
  was late to notice it. `occurred_at` is also what the index and the dashboard
  order by, so the retention cut matches the window an organiser can actually
  see.

  A zero, negative, or non-integer window deletes nothing. The audit exists to
  outlive the state that produced it, and a misconfigured retention that silently
  emptied it would destroy the only record of every resolution ever made.
  """
  @spec prune_older_than(integer()) :: {non_neg_integer(), nil}
  def prune_older_than(days) when is_integer(days) and days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    BatchDeleteQueries.delete_older_than(CalendarSyncConflictSchema, :occurred_at, cutoff)
  end

  def prune_older_than(_days), do: {0, nil}
end
