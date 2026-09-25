defmodule Tymeslot.Workers.DeliveryClaims.DeliveryClaimQueries do
  @moduledoc """
  Database access for `Tymeslot.Workers.DeliveryClaims`.
  """

  import Ecto.Query

  alias Tymeslot.Repo
  alias Tymeslot.Workers.DeliveryClaims.DeliveryClaimSchema

  @doc """
  Records the claim, or reports that it is already held. The unique index on
  `(oban_job_id, effect_key)` is what makes this atomic: two executions racing
  for the same claim cannot both insert it.
  """
  @spec claim(integer(), String.t()) :: :claimed | :already_claimed
  def claim(oban_job_id, effect_key) do
    row = %{
      oban_job_id: oban_job_id,
      effect_key: effect_key,
      inserted_at: DateTime.utc_now(:second)
    }

    case Repo.insert_all(DeliveryClaimSchema, [row],
           on_conflict: :nothing,
           conflict_target: [:oban_job_id, :effect_key]
         ) do
      {1, _rows} -> :claimed
      {0, _rows} -> :already_claimed
    end
  end

  @doc "Drops a claim, so a later execution of the job may perform the effect."
  @spec release(integer(), String.t()) :: :ok
  def release(oban_job_id, effect_key) do
    DeliveryClaimSchema
    |> where([c], c.oban_job_id == ^oban_job_id and c.effect_key == ^effect_key)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Deletes the claims whose job no longer exists. Oban prunes finished jobs,
  and a claim is only ever consulted by a later run of its own job.
  """
  @spec delete_orphaned() :: non_neg_integer()
  def delete_orphaned do
    {count, _rows} =
      DeliveryClaimSchema
      |> from(as: :claim)
      |> where(
        [c],
        not exists(from(j in Oban.Job, where: j.id == parent_as(:claim).oban_job_id))
      )
      |> Repo.delete_all()

    count
  end

  @doc "Whether the claim is held. For tests and diagnostics."
  @spec claimed?(integer(), String.t()) :: boolean()
  def claimed?(oban_job_id, effect_key) do
    DeliveryClaimSchema
    |> where([c], c.oban_job_id == ^oban_job_id and c.effect_key == ^effect_key)
    |> Repo.exists?()
  end
end
