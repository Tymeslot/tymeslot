defmodule Tymeslot.Polls.PollTimeSlotSchema do
  @moduledoc "A candidate time slot proposed in a poll."

  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.Polls.{PollSchema, PollVoteSchema}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "poll_time_slots" do
    field(:start_time, :utc_datetime)
    field(:end_time, :utc_datetime)
    field(:position, :integer, default: 0)

    belongs_to(:poll, PollSchema)
    has_many(:votes, PollVoteSchema, foreign_key: :poll_time_slot_id)

    timestamps(type: :utc_datetime)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(slot, attrs) do
    slot
    |> cast(attrs, [:poll_id, :start_time, :end_time, :position])
    |> validate_required([:poll_id, :start_time, :end_time])
    |> validate_time_order()
    |> unique_constraint([:poll_id, :start_time])
    |> foreign_key_constraint(:poll_id)
  end

  defp validate_time_order(changeset) do
    start_time = get_field(changeset, :start_time)
    end_time = get_field(changeset, :end_time)

    if start_time && end_time && DateTime.compare(end_time, start_time) != :gt do
      add_error(changeset, :end_time, "must be after the start time")
    else
      changeset
    end
  end
end
