defmodule Tymeslot.Analytics.EventQueries do
  @moduledoc """
  Read-only queries over `analytics_events`.

  All `Repo.*` calls for analytics events live here per the
  `CredoChecks.RepoCallBoundary` rule.
  """
  import Ecto.Query

  alias Tymeslot.Analytics.EventSchema
  alias Tymeslot.Infrastructure.BatchDeleteQueries
  alias Tymeslot.Repo

  @spec insert(map()) :: {:ok, EventSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert(attrs) do
    %EventSchema{} |> EventSchema.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Deletes analytics events older than `days`. One row is written per page view,
  so this table grows unbounded without pruning. Deletes in bounded batches
  (see `BatchDeleteQueries`) so a large backlog can't blow past the database
  timeout in a single transaction. A zero, negative, or non-integer retention
  is treated as a no-op so a misconfigured value can never wipe the whole
  table.
  """
  @spec delete_events_older_than(integer()) :: {non_neg_integer(), nil}
  def delete_events_older_than(days) when is_integer(days) and days > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    BatchDeleteQueries.delete_older_than(EventSchema, :inserted_at, cutoff)
  end

  def delete_events_older_than(_days), do: {0, nil}

  @spec count_visits(integer(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  def count_visits(user_id, from, to) do
    EventSchema
    |> where([e], e.user_id == ^user_id)
    |> where([e], e.inserted_at >= ^from and e.inserted_at <= ^to)
    |> select([e], count(e.id))
    |> Repo.one() || 0
  end

  @spec count_unique_visitors(integer(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  def count_unique_visitors(user_id, from, to) do
    EventSchema
    |> where([e], e.user_id == ^user_id)
    |> where([e], e.inserted_at >= ^from and e.inserted_at <= ^to)
    |> select([e], count(e.visitor_hash, :distinct))
    |> Repo.one() || 0
  end

  @spec top_sources_with_unique(integer(), DateTime.t(), DateTime.t()) :: [
          %{utm_source: String.t(), visits: non_neg_integer(), unique_visitors: non_neg_integer()}
        ]
  def top_sources_with_unique(user_id, from, to) do
    EventSchema
    |> where([e], e.user_id == ^user_id)
    |> where([e], e.inserted_at >= ^from and e.inserted_at <= ^to)
    |> where([e], not is_nil(e.utm_source))
    |> group_by([e], e.utm_source)
    |> select([e], %{
      utm_source: e.utm_source,
      visits: count(e.id),
      unique_visitors: count(e.visitor_hash, :distinct)
    })
    |> order_by([e], desc: count(e.id), asc: e.utm_source)
    |> Repo.all()
  end

  @spec device_breakdown(integer(), DateTime.t(), DateTime.t()) :: [
          %{device_type: String.t(), visits: non_neg_integer()}
        ]
  def device_breakdown(user_id, from, to) do
    EventSchema
    |> where([e], e.user_id == ^user_id)
    |> where([e], e.inserted_at >= ^from and e.inserted_at <= ^to)
    |> group_by([e], e.device_type)
    |> select([e], %{
      device_type: coalesce(e.device_type, "unknown"),
      visits: count(e.id)
    })
    |> order_by([e], desc: count(e.id))
    |> Repo.all()
  end

  @spec visits_by_day(integer(), DateTime.t(), DateTime.t(), String.t()) :: [
          %{day: Date.t(), visits: non_neg_integer()}
        ]
  def visits_by_day(user_id, from, to, time_zone) do
    # Bucket by the organizer's local calendar day: `inserted_at` is UTC wall
    # time, so reinterpret it as UTC then shift into the target zone before
    # truncating. `selected_as/2` is required so GROUP BY/ORDER BY reference the
    # aliased column rather than re-binding the `time_zone` parameter (which
    # Postgres would treat as a distinct expression).
    EventSchema
    |> where([e], e.user_id == ^user_id)
    |> where([e], e.inserted_at >= ^from and e.inserted_at <= ^to)
    |> select([e], %{
      day:
        selected_as(
          fragment(
            "(date_trunc('day', (? AT TIME ZONE 'UTC') AT TIME ZONE ?))::date",
            e.inserted_at,
            ^time_zone
          ),
          :day
        ),
      visits: count(e.id)
    })
    |> group_by([e], selected_as(:day))
    |> order_by([e], selected_as(:day))
    |> Repo.all()
  end
end
