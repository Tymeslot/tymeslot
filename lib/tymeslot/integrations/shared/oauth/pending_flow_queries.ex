defmodule Tymeslot.Integrations.Shared.OAuth.PendingFlowQueries do
  @moduledoc """
  Database access for `Tymeslot.Integrations.Shared.OAuth.PendingFlowSchema`.
  """

  import Ecto.Query

  alias Tymeslot.Integrations.Shared.OAuth.PendingFlowSchema
  alias Tymeslot.Repo

  @spec insert(map()) :: {:ok, PendingFlowSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert(attrs) do
    %PendingFlowSchema{}
    |> PendingFlowSchema.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Marks `user_id`'s unexpired, unconsumed `provider` flow `nonce` consumed
  and returns it, in one conditional update: of two callbacks racing on one
  flow, exactly one gets it.
  """
  @spec consume(String.t(), pos_integer(), String.t(), DateTime.t()) ::
          {:ok, PendingFlowSchema.t()} | :error
  def consume(nonce, user_id, provider, now) do
    query =
      from(f in PendingFlowSchema,
        where:
          f.nonce == ^nonce and f.user_id == ^user_id and f.provider == ^provider and
            is_nil(f.consumed_at) and f.expires_at > ^now,
        select: f
      )

    case Repo.update_all(query, set: [consumed_at: now, updated_at: now]) do
      {1, [flow]} -> {:ok, flow}
      {0, []} -> :error
    end
  end

  @doc "Deletes flows that expired before `now`, consumed or not."
  @spec delete_expired(DateTime.t()) :: {non_neg_integer(), nil}
  def delete_expired(now) do
    Repo.delete_all(from(f in PendingFlowSchema, where: f.expires_at <= ^now))
  end
end
