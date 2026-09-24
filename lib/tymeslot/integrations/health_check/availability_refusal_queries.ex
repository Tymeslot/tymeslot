defmodule Tymeslot.Integrations.HealthCheck.AvailabilityRefusalQueries do
  @moduledoc """
  Database queries for the `calendar_availability_refusals` hourly counters.
  """

  import Ecto.Query

  alias Tymeslot.Clock
  alias Tymeslot.Integrations.HealthCheck.AvailabilityRefusalSchema
  alias Tymeslot.Repo

  @doc """
  Adds one refusal to `user_id`'s counter for the hour starting at
  `bucket_start`, creating the counter on the hour's first refusal.
  """
  @spec increment(pos_integer(), DateTime.t()) ::
          {:ok, AvailabilityRefusalSchema.t()} | {:error, Ecto.Changeset.t()}
  def increment(user_id, %DateTime{} = bucket_start) do
    %AvailabilityRefusalSchema{}
    |> AvailabilityRefusalSchema.changeset(%{
      user_id: user_id,
      bucket_start: bucket_start,
      refusals: 1
    })
    |> Repo.insert(
      on_conflict: [
        inc: [refusals: 1],
        set: [updated_at: DateTime.truncate(Clock.utc_now(), :second)]
      ],
      conflict_target: [:user_id, :bucket_start]
    )
  end

  @doc """
  The users refused at least `min_refusals` times in the buckets starting
  within `[from, to)`, as `{user_id, refusals}` pairs, most refused first.
  """
  @spec users_refused_at_least(DateTime.t(), DateTime.t(), pos_integer()) ::
          [{pos_integer(), pos_integer()}]
  def users_refused_at_least(%DateTime{} = from, %DateTime{} = to, min_refusals) do
    AvailabilityRefusalSchema
    |> where([r], r.bucket_start >= ^from and r.bucket_start < ^to)
    |> group_by([r], r.user_id)
    |> having([r], sum(r.refusals) >= ^min_refusals)
    |> select([r], {r.user_id, type(sum(r.refusals), :integer)})
    |> order_by([r], desc: sum(r.refusals), asc: r.user_id)
    |> Repo.all()
  end

  @doc """
  Deletes the counters for hours that started more than `days` days ago.
  """
  @spec prune_older_than(pos_integer()) :: {non_neg_integer(), nil}
  def prune_older_than(days) do
    cutoff = DateTime.add(Clock.utc_now(), -days, :day)

    AvailabilityRefusalSchema
    |> where([r], r.bucket_start < ^cutoff)
    |> Repo.delete_all()
  end
end
