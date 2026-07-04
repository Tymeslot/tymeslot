defmodule Tymeslot.Infrastructure.BatchDeleteQueries do
  @moduledoc """
  Shared helper for retention-style `delete_all` queries.

  A single unbounded `delete_all` over a cutoff timestamp can, on the first
  run after deploy, try to remove a huge backlog in one transaction and blow
  past the Postgrex statement timeout — exhausting an Oban worker's
  `max_attempts` without ever making progress. This module deletes in
  bounded batches instead, via a subquery on primary key (Postgres
  `delete_all` doesn't accept a direct `LIMIT`), looping until a batch comes
  back short.

  Used by the retention `delete_all` functions in `*_queries.ex` modules
  across domains (analytics, telegram, slack, webhooks) — the deletion
  shape ("rows older than a cutoff, on a timestamp column") is identical;
  only the schema and column differ.
  """

  import Ecto.Query

  alias Tymeslot.Repo

  @delete_batch_size 10_000

  @doc """
  Deletes rows from `queryable` where `timestamp_field` is older than
  `cutoff`, in batches of #{@delete_batch_size}. Returns `{total_deleted,
  nil}` so callers can keep treating it like a plain `Repo.delete_all/2`
  result.
  """
  @spec delete_older_than(Ecto.Queryable.t(), atom(), DateTime.t()) ::
          {non_neg_integer(), nil}
  def delete_older_than(queryable, timestamp_field, %DateTime{} = cutoff) do
    {delete_batch(queryable, timestamp_field, cutoff, 0), nil}
  end

  defp delete_batch(queryable, timestamp_field, cutoff, total) do
    ids_query =
      queryable
      |> where([q], field(q, ^timestamp_field) < ^cutoff)
      |> select([q], q.id)
      |> limit(@delete_batch_size)

    {deleted, nil} =
      queryable
      |> where([q], q.id in subquery(ids_query))
      |> Repo.delete_all()

    total = total + deleted

    if deleted < @delete_batch_size do
      total
    else
      delete_batch(queryable, timestamp_field, cutoff, total)
    end
  end
end
