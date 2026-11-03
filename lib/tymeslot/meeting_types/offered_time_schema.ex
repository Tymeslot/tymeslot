defmodule Tymeslot.MeetingTypes.OfferedTimeSchema do
  @moduledoc """
  One exact start time a one-to-one meeting type with fixed dates offers
  (`Tymeslot.MeetingTypes.OfferedTimes`). It is not a meeting: booking it
  makes an ordinary one.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  @type t :: %__MODULE__{
          id: integer() | nil,
          meeting_type_id: integer() | nil,
          starts_at: DateTime.t() | nil,
          meeting_type: MeetingTypeSchema.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "meeting_type_offered_times" do
    field(:starts_at, :utc_datetime)

    belongs_to(:meeting_type, MeetingTypeSchema)

    timestamps(type: :utc_datetime)
  end

  @doc "A new offered time of `meeting_type_id` starting at `starts_at` (UTC)."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(offered_time, attrs) do
    offered_time
    |> cast(attrs, [:meeting_type_id, :starts_at])
    |> validate_required([:meeting_type_id, :starts_at])
    |> foreign_key_constraint(:meeting_type_id)
    |> unique_constraint(:starts_at,
      name: :meeting_type_offered_times_meeting_type_id_starts_at_index
    )
  end
end
