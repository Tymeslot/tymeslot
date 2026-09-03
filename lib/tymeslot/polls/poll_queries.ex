defmodule Tymeslot.Polls.PollQueries do
  @moduledoc "Data access for polls."

  import Ecto.Query

  alias Tymeslot.Polls.PollSchema
  alias Tymeslot.Repo

  @preloads [time_slots: [], participants: [:votes]]

  # The public voting page additionally needs the confirmed meeting so it can
  # show the scheduled time once a poll has been confirmed.
  @voting_preloads [time_slots: [], participants: [:votes], confirmed_meeting: []]

  @spec get_by_token(String.t()) :: PollSchema.t() | nil
  def get_by_token(token) when is_binary(token) do
    PollSchema
    |> where([p], p.token == ^token)
    |> preload(^@voting_preloads)
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

  @doc """
  Fetches a poll for its owner, locking the row for the surrounding transaction.

  Must be called inside `Repo.transaction/1`. Confirmation reads the poll's
  status and then writes it, so the read has to hold the row until the write
  commits; without the lock two concurrent confirms both see `:open` and both
  mint a meeting. Associations are preloaded by a second query rather than a
  join, because Postgres rejects `FOR UPDATE` against an outer-joined row.
  """
  @spec lock_for_user(Ecto.UUID.t(), pos_integer()) :: PollSchema.t() | nil
  def lock_for_user(id, user_id) do
    PollSchema
    |> where([p], p.id == ^id and p.user_id == ^user_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> preload_associations()
  end

  defp preload_associations(nil), do: nil
  defp preload_associations(poll), do: Repo.preload(poll, @preloads)

  @spec list_for_user(pos_integer()) :: [PollSchema.t()]
  def list_for_user(user_id) do
    PollSchema
    |> where([p], p.user_id == ^user_id)
    |> order_by([p], desc: p.inserted_at)
    |> preload(^@preloads)
    |> Repo.all()
  end

  @doc """
  Counts the user's polls that are still collecting votes.

  Participants reach a poll by a link built from the host's username, so this
  is the count of invitations that a username change would strand. Confirmed
  and cancelled polls are excluded: nobody is being asked to open their link
  any more.
  """
  @spec count_open_for_user(pos_integer()) :: non_neg_integer()
  def count_open_for_user(user_id) do
    PollSchema
    |> where([p], p.user_id == ^user_id and p.status == :open)
    |> Repo.aggregate(:count)
  end

  @spec insert(Ecto.Changeset.t()) :: {:ok, PollSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert(changeset), do: Repo.insert(changeset)

  @spec update(Ecto.Changeset.t()) :: {:ok, PollSchema.t()} | {:error, Ecto.Changeset.t()}
  def update(changeset), do: Repo.update(changeset)
end
