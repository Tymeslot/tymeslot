defmodule Tymeslot.Polls.PollVoteSchema do
  @moduledoc "One participant's response to one candidate slot."

  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.Polls.{PollParticipantSchema, PollTimeSlotSchema}

  @responses [:yes, :if_need_be, :no]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "poll_votes" do
    field(:response, Ecto.Enum, values: @responses)

    belongs_to(:participant, PollParticipantSchema, foreign_key: :poll_participant_id)
    belongs_to(:time_slot, PollTimeSlotSchema, foreign_key: :poll_time_slot_id)

    timestamps(type: :utc_datetime)
  end

  def responses, do: @responses

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(vote, attrs) do
    vote
    |> cast(attrs, [:poll_participant_id, :poll_time_slot_id, :response])
    |> validate_required([:poll_participant_id, :poll_time_slot_id, :response])
    |> unique_constraint([:poll_participant_id, :poll_time_slot_id])
    |> foreign_key_constraint(:poll_participant_id)
    |> foreign_key_constraint(:poll_time_slot_id)
  end
end
