defmodule Tymeslot.Polls.PollQueries do
  @moduledoc "Data access for polls."

  import Ecto.Query

  alias Tymeslot.Polls.PollSchema
  alias Tymeslot.Repo

  @preloads [time_slots: [], participants: [:votes]]

  @spec get_by_token(String.t()) :: PollSchema.t() | nil
  def get_by_token(token) when is_binary(token) do
    PollSchema
    |> where([p], p.token == ^token)
    |> preload(^@preloads)
    |> Repo.one()
  end

  @doc "Fetches a poll by id with its host (user and profile) preloaded, for email sending."
  @spec get_with_host(Ecto.UUID.t()) :: PollSchema.t() | nil
  def get_with_host(id) do
    PollSchema
    |> where([p], p.id == ^id)
    |> preload(user: :profile)
    |> Repo.one()
  end

  @spec get_for_user(Ecto.UUID.t(), pos_integer()) :: PollSchema.t() | nil
  def get_for_user(id, user_id) do
    PollSchema
    |> where([p], p.id == ^id and p.user_id == ^user_id)
    |> preload(^@preloads)
    |> Repo.one()
  end

  @spec list_for_user(pos_integer()) :: [PollSchema.t()]
  def list_for_user(user_id) do
    PollSchema
    |> where([p], p.user_id == ^user_id)
    |> order_by([p], desc: p.inserted_at)
    |> preload(^@preloads)
    |> Repo.all()
  end

  @spec insert(Ecto.Changeset.t()) :: {:ok, PollSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert(changeset), do: Repo.insert(changeset)

  @spec update(Ecto.Changeset.t()) :: {:ok, PollSchema.t()} | {:error, Ecto.Changeset.t()}
  def update(changeset), do: Repo.update(changeset)
end
