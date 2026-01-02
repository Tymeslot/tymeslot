defmodule Tymeslot.DatabaseSchemas.WeeklyAvailabilitySchema do
  @moduledoc """
  Schema for weekly availability settings per day of week.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.DatabaseSchemas.{AvailabilityBreakSchema, ProfileSchema}

  @type t :: %__MODULE__{
          id: integer() | nil,
          profile_id: integer() | nil,
          day_of_week: integer() | nil,
          is_available: boolean(),
          start_time: Time.t() | nil,
          end_time: Time.t() | nil,
          profile: ProfileSchema.t() | Ecto.Association.NotLoaded.t(),
          breaks: [AvailabilityBreakSchema.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "weekly_availability" do
    field(:day_of_week, :integer)
    field(:is_available, :boolean, default: false)
    field(:start_time, :time)
    field(:end_time, :time)

    belongs_to(:profile, ProfileSchema)
    has_many(:breaks, AvailabilityBreakSchema, foreign_key: :weekly_availability_id)

    timestamps()
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(weekly_availability, attrs) do
    weekly_availability
    |> cast(attrs, [:profile_id, :day_of_week, :is_available, :start_time, :end_time])
    |> validate_required([:profile_id, :day_of_week])
    |> validate_inclusion(:day_of_week, 1..7,
      message: "must be between 1 (Monday) and 7 (Sunday)"
    )
    |> validate_times()
    |> unique_constraint([:profile_id, :day_of_week])
    |> foreign_key_constraint(:profile_id)
  end

  defp validate_times(changeset) do
    is_available = get_field(changeset, :is_available)
    start_time = get_field(changeset, :start_time)
    end_time = get_field(changeset, :end_time)

    if is_available do
      changeset
      |> validate_required([:start_time, :end_time],
        message: "are required when day is available"
      )
      |> validate_time_order(start_time, end_time)
    else
      changeset
    end
  end

  defp validate_time_order(changeset, start_time, end_time) do
    if start_time && end_time && Time.compare(start_time, end_time) != :lt do
      add_error(changeset, :end_time, "must be after start time")
    else
      changeset
    end
  end
end
