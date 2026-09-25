defmodule Tymeslot.Infrastructure.ErrorTracking.ErrorTrackingQueries do
  @moduledoc """
  Housekeeping queries over ErrorTracker's tables, always through its own
  schemas (`ErrorTracker.Error`, `ErrorTracker.Occurrence`) so a table
  rename in the library cannot leave a hardcoded name behind.

  ErrorTracker's Postgres migration indexes `error_tracker_errors` on
  `fingerprint` (unique) and `last_occurrence_at`, and
  `error_tracker_occurrences` on `error_id` only. The queries here are
  shaped to those indexes: resolving filters on `last_occurrence_at`, and
  trimming occurrences always narrows by `error_id` first rather than
  ranking the whole occurrences table.
  """

  import Ecto.Query

  alias ErrorTracker.Error
  alias ErrorTracker.Occurrence
  alias ErrorTracker.Plugins.Pruner
  alias Tymeslot.Repo

  @prune_batch_size 200
  @error_batch_size 100
  @occurrence_batch_size 1_000

  @doc """
  Returns true when the calling process is inside a transaction on the
  repository ErrorTracker writes to, as configured under `:error_tracker,
  :repo`.
  """
  @spec in_transaction?() :: boolean()
  def in_transaction?, do: Application.fetch_env!(:error_tracker, :repo).in_transaction?()

  @doc """
  Replaces an error's stored reason with `scrubbed`, but only while it still
  reads `raw`: a later occurrence's report cannot overwrite a newer value.
  Returns `:ok` whether or not a row changed.
  """
  @spec replace_error_reason(pos_integer(), String.t(), String.t()) :: :ok
  def replace_error_reason(id, raw, scrubbed),
    do: replace_reason(from(e in Error, where: e.id == ^id and e.reason == ^raw), scrubbed)

  @doc "As `replace_error_reason/3`, for one occurrence."
  @spec replace_occurrence_reason(pos_integer(), String.t(), String.t()) :: :ok
  def replace_occurrence_reason(id, raw, scrubbed),
    do: replace_reason(from(o in Occurrence, where: o.id == ^id and o.reason == ^raw), scrubbed)

  defp replace_reason(query, scrubbed) do
    {_count, _rows} = Repo.update_all(query, set: [reason: scrubbed])
    :ok
  end

  @doc """
  Marks every unresolved error last seen before `cutoff` as resolved,
  muted ones included. Returns the number of errors resolved.

  This writes the column directly rather than through `ErrorTracker.resolve/1`,
  so ErrorTracker's `[:error_tracker, :error, :resolved]` telemetry event is
  not emitted; nothing in the application listens to it.
  """
  @spec resolve_last_seen_before(DateTime.t()) :: non_neg_integer()
  def resolve_last_seen_before(%DateTime{} = cutoff) do
    {count, _rows} =
      Repo.update_all(
        from(e in Error, where: e.status == :unresolved and e.last_occurrence_at < ^cutoff),
        set: [status: :resolved, updated_at: DateTime.utc_now()]
      )

    count
  end

  @doc """
  Deletes resolved errors last seen more than `max_age_ms` ago, with their
  occurrences, through `ErrorTracker.Plugins.Pruner.prune_errors/1`. The
  pruner takes at most one batch per call, so this calls it until a batch
  comes back short. Returns the number of errors deleted.
  """
  @spec prune_resolved(pos_integer(), keyword()) :: non_neg_integer()
  def prune_resolved(max_age_ms, opts \\ []) when is_integer(max_age_ms) and max_age_ms > 0 do
    batch_size = Keyword.get(opts, :batch_size, @prune_batch_size)
    prune_resolved_batches(max_age_ms, batch_size, 0)
  end

  defp prune_resolved_batches(max_age_ms, batch_size, total) do
    {:ok, pruned} = Pruner.prune_errors(limit: batch_size, max_age: max_age_ms)
    total = total + length(pruned)

    if length(pruned) < batch_size,
      do: total,
      else: prune_resolved_batches(max_age_ms, batch_size, total)
  end

  @doc """
  Deletes occurrences of unresolved errors inserted before `cutoff`, except
  that each error keeps its newest `keep` occurrences whatever their age.
  An occurrence inside the window is never deleted.

  Walks the unresolved errors by id, a batch at a time, and deletes in
  bounded batches within each, so a large backlog never becomes one long
  statement. Returns the number of occurrences deleted.
  """
  @spec trim_unresolved_occurrences(DateTime.t(), non_neg_integer(), keyword()) ::
          non_neg_integer()
  def trim_unresolved_occurrences(%DateTime{} = cutoff, keep, opts \\ [])
      when is_integer(keep) and keep >= 0 do
    batch_sizes = %{
      errors: Keyword.get(opts, :error_batch_size, @error_batch_size),
      occurrences: Keyword.get(opts, :occurrence_batch_size, @occurrence_batch_size)
    }

    trim_error_batches(cutoff, keep, batch_sizes, 0, 0)
  end

  defp trim_error_batches(cutoff, keep, batch_sizes, after_id, total) do
    error_ids =
      Repo.all(
        from e in Error,
          where: e.status == :unresolved and e.id > ^after_id,
          order_by: e.id,
          limit: ^batch_sizes.errors,
          select: e.id
      )

    case error_ids do
      [] ->
        total

      ids ->
        deleted = delete_ranked_out(ids, cutoff, keep, batch_sizes.occurrences, 0)
        trim_error_batches(cutoff, keep, batch_sizes, List.last(ids), total + deleted)
    end
  end

  # Every deleted row ranks below the `keep` newest of its error, so the
  # survivors' ranks are stable across batches and re-ranking is safe.
  defp delete_ranked_out(error_ids, cutoff, keep, batch_size, total) do
    ranked =
      from o in Occurrence,
        where: o.error_id in ^error_ids,
        select: %{
          id: o.id,
          inserted_at: o.inserted_at,
          rank:
            over(row_number(),
              partition_by: o.error_id,
              order_by: [desc: o.inserted_at, desc: o.id]
            )
        }

    doomed =
      from r in subquery(ranked),
        where: r.rank > ^keep and r.inserted_at < ^cutoff,
        limit: ^batch_size,
        select: r.id

    {deleted, _rows} = Repo.delete_all(from o in Occurrence, where: o.id in subquery(doomed))
    total = total + deleted

    if deleted < batch_size,
      do: total,
      else: delete_ranked_out(error_ids, cutoff, keep, batch_size, total)
  end
end
