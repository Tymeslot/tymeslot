defmodule Tymeslot.Polls.PollTimeSlotQueries do
  @moduledoc "Data access for poll time slots."

  import Ecto.Query

  alias Tymeslot.Polls.PollTimeSlotSchema
  alias Tymeslot.Repo

  @spec insert(Ecto.Changeset.t()) ::
          {:ok, PollTimeSlotSchema.t()} | {:error, Ecto.Changeset.t()}
  def insert(changeset), do: Repo.insert(changeset)

  @spec get_for_poll(Ecto.UUID.t(), Ecto.UUID.t()) :: PollTimeSlotSchema.t() | nil
  def get_for_poll(slot_id, poll_id) do
    PollTimeSlotSchema
    |> where([s], s.id == ^slot_id and s.poll_id == ^poll_id)
    |> Repo.one()
  end

  @spec count_for_poll(Ecto.UUID.t()) :: non_neg_integer()
  def count_for_poll(poll_id) do
    PollTimeSlotSchema
    |> where([s], s.poll_id == ^poll_id)
    |> Repo.aggregate(:count)
  end
end
