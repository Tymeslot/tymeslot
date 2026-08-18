defmodule Tymeslot.Polls.PollParticipantQueries do
  @moduledoc "Data access for poll participants."

  import Ecto.Query

  alias Tymeslot.Polls.PollParticipantSchema
  alias Tymeslot.Repo

  @spec insert(Ecto.Changeset.t()) ::
          {:ok, PollParticipantSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert(changeset), do: Repo.insert(changeset)

  @spec update(Ecto.Changeset.t()) ::
          {:ok, PollParticipantSchema.t()} | {:error, Ecto.Changeset.t()}
  def update(changeset), do: Repo.update(changeset)

  @spec get_by_token(String.t()) :: PollParticipantSchema.t() | nil
  def get_by_token(token) when is_binary(token) do
    PollParticipantSchema
    |> where([p], p.token == ^token)
    |> preload(:votes)
    |> Repo.one()
  end

  @spec get_by_poll_and_email(Ecto.UUID.t(), String.t()) :: PollParticipantSchema.t() | nil
  def get_by_poll_and_email(poll_id, email) do
    PollParticipantSchema
    |> where([p], p.poll_id == ^poll_id and p.email == ^email)
    |> preload(:votes)
    |> Repo.one()
  end

  @spec count_for_poll(Ecto.UUID.t()) :: non_neg_integer()
  def count_for_poll(poll_id) do
    PollParticipantSchema
    |> where([p], p.poll_id == ^poll_id)
    |> Repo.aggregate(:count)
  end

  @spec list_unvoted_for_poll(Ecto.UUID.t()) :: [PollParticipantSchema.t()]
  def list_unvoted_for_poll(poll_id) do
    PollParticipantSchema
    |> where([p], p.poll_id == ^poll_id and is_nil(p.voted_at))
    |> Repo.all()
  end
end
