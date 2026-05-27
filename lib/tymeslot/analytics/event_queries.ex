defmodule Tymeslot.Analytics.EventQueries do
  @moduledoc """
  Read-only queries over `analytics_events`.

  All `Repo.*` calls for analytics events live here per the
  `CredoChecks.RepoCallBoundary` rule.
  """
  import Ecto.Query

  alias Tymeslot.Analytics.EventSchema
  alias Tymeslot.Repo

  @spec insert(map()) :: {:ok, EventSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert(attrs) do
    %EventSchema{} |> EventSchema.changeset(attrs) |> Repo.insert()
  end

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

  @spec top_sources(integer(), DateTime.t(), DateTime.t()) :: [
          %{utm_source: String.t() | nil, visits: non_neg_integer()}
        ]
  def top_sources(user_id, from, to) do
    EventSchema
    |> where([e], e.user_id == ^user_id)
    |> where([e], e.inserted_at >= ^from and e.inserted_at <= ^to)
    |> group_by([e], e.utm_source)
    |> select([e], %{utm_source: e.utm_source, visits: count(e.id)})
    |> order_by([e], desc: count(e.id))
    |> Repo.all()
  end

  @spec visits_by_day(integer(), DateTime.t(), DateTime.t()) :: [
          %{day: Date.t(), visits: non_neg_integer()}
        ]
  def visits_by_day(user_id, from, to) do
    EventSchema
    |> where([e], e.user_id == ^user_id)
    |> where([e], e.inserted_at >= ^from and e.inserted_at <= ^to)
    |> group_by([e], fragment("date_trunc('day', ?)", e.inserted_at))
    |> select([e], %{
      day: fragment("date_trunc('day', ?)::date", e.inserted_at),
      visits: count(e.id)
    })
    |> order_by([e], fragment("date_trunc('day', ?)", e.inserted_at))
    |> Repo.all()
  end
end
