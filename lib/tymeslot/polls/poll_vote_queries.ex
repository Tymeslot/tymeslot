defmodule Tymeslot.Polls.PollVoteQueries do
  @moduledoc "Data access for poll votes."

  import Ecto.Query

  alias Ecto.UUID
  alias Tymeslot.Polls.PollVoteSchema
  alias Tymeslot.Repo

  @spec upsert_votes([map()]) :: {non_neg_integer(), nil | [term()]}
  def upsert_votes(vote_maps) when is_list(vote_maps) do
    now = DateTime.utc_now(:second)

    rows =
      Enum.map(vote_maps, fn vote ->
        vote
        |> Map.put(:id, UUID.generate())
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    Repo.insert_all(PollVoteSchema, rows,
      on_conflict: {:replace, [:response, :updated_at]},
      conflict_target: [:poll_participant_id, :poll_time_slot_id]
    )
  end

  @spec list_for_participant(Ecto.UUID.t()) :: [PollVoteSchema.t()]
  def list_for_participant(participant_id) do
    PollVoteSchema
    |> where([v], v.poll_participant_id == ^participant_id)
    |> Repo.all()
  end
end
