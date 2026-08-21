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
  The most recent conflict of one kind for one source on one link.

  Exists for the kinds whose condition *persists* rather than describing a
  moment — `occurrence_moved`, today. A moved occurrence stays moved: the
  placeholder goes on expanding it at its original time until the organiser
  moves it back or correction is built, so every sync of that calendar sees the
  same divergence again. Without this the log would gain a row per sync for a
  finding the organiser was told about once, and its row count — which is the
  measure the kind exists to produce — would read as a frequency it is not.

  `{:error, :not_found}` means nothing of that kind has been recorded for this
  source, which the caller reads as "report it".

  Scoped to `source_uid` as well as the link, because the question is always
  about one event's history: another series' moves say nothing about this one's.
  """
  @spec last_of_kind(integer(), String.t(), String.t()) ::
          {:ok, CalendarSyncConflictSchema.t()} | {:error, :not_found}
  def last_of_kind(sync_link_id, source_uid, kind)
      when is_integer(sync_link_id) and is_binary(source_uid) and is_binary(kind) do
    latest =
      CalendarSyncConflictSchema
      |> where([c], c.sync_link_id == ^sync_link_id)
      |> where([c], c.source_uid == ^source_uid)
      |> where([c], c.kind == ^kind)
      |> order_by([c], desc: c.occurred_at, desc: c.id)
      |> limit(1)
      |> Repo.one()

    case latest do
      nil -> {:error, :not_found}
      conflict -> {:ok, conflict}
    end
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

  The cap is per link and applied in SQL, by numbering each link's rows in a
  window partitioned on `sync_link_id` and keeping the first `limit` of each.
  A plain `LIMIT` would be the wrong shape: it caps the result overall, so one
  busy link could fill the whole allowance and leave a quieter one's section
  blank on a dashboard that has divergences to show it.

  The window is what the cap has to be, not merely a faster way to reach the
  same answer. Narrowing to one organiser's links bounds nothing — retention
  keeps 90 days, and grouping in Elixir after an unbounded `Repo.all()` loads
  and sorts every one of those rows on every dashboard render to then discard
  all but a handful per link.

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

    # Dismissed rows are excluded rather than marked: the listing is what backs
    # the count, and a count that included rows the organiser has already
    # cleared would never reach zero however many times they cleared it.
    ranked =
      CalendarSyncConflictSchema
      |> where([c], c.sync_link_id in ^sync_link_ids and is_nil(c.dismissed_at))
      |> select([c], %{
        id: c.id,
        rank:
          over(row_number(),
            partition_by: c.sync_link_id,
            order_by: [desc: c.occurred_at, desc: c.id]
          )
      })

    # Re-joined to the table rather than selecting every column through the
    # window: the subquery carries only the ids that survive the cap, and the
    # outer query loads whole schema structs for exactly those, so the caller
    # still gets the rows it would have got before.
    CalendarSyncConflictSchema
    |> join(:inner, [c], r in subquery(ranked), on: r.id == c.id and r.rank <= ^limit)
    |> order_by([c], desc: c.occurred_at, desc: c.id)
    |> Repo.all()
    |> Enum.group_by(& &1.sync_link_id)
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

  @doc """
  Marks every undismissed conflict on these links as seen.

  Takes link ids rather than a user id: this module is not user-scoped, and
  the caller — `SyncLink.dismiss_conflicts/2` — has already resolved which
  links the acting organiser owns. Passing ids that survived that check is what
  keeps the authorisation in one place.

  Already-dismissed rows are left alone rather than restamped, so the column
  keeps recording when a resolution was *first* seen. That is the half that
  answers "the warning came back": a second stamp would erase the evidence that
  the row predates the last time the organiser cleared the list.
  """
  @spec dismiss_for_links([integer()], DateTime.t()) :: {:ok, non_neg_integer()}
  def dismiss_for_links([], _now), do: {:ok, 0}

  def dismiss_for_links(sync_link_ids, now) when is_list(sync_link_ids) do
    {count, _returned} =
      CalendarSyncConflictSchema
      |> where([c], c.sync_link_id in ^sync_link_ids and is_nil(c.dismissed_at))
      |> Repo.update_all(set: [dismissed_at: now, updated_at: now])

    {:ok, count}
  end
end
