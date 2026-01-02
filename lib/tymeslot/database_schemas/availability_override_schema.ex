defmodule Tymeslot.DatabaseSchemas.AvailabilityOverrideSchema do
  @moduledoc """
  Schema for date-specific availability overrides.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.DatabaseSchemas.ProfileSchema

  @type t :: %__MODULE__{
          id: integer() | nil,
          profile_id: integer() | nil,
          date: Date.t() | nil,
          override_type: String.t() | nil,
          start_time: Time.t() | nil,
          end_time: Time.t() | nil,
          reason: String.t() | nil,
          profile: ProfileSchema.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @override_types ~w(unavailable custom_hours available)

  schema "availability_overrides" do
    field(:date, :date)
    field(:override_type, :string)
    field(:start_time, :time)
    field(:end_time, :time)
    field(:reason, :string)

    belongs_to(:profile, ProfileSchema)

    timestamps()
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(override, attrs) do
    override
    |> cast(attrs, [:profile_id, :date, :override_type, :start_time, :end_time, :reason])
    |> validate_required([:profile_id, :date, :override_type])
    |> validate_inclusion(:override_type, @override_types)
    |> validate_times()
    |> validate_reason()
    |> unique_constraint([:profile_id, :date])
    |> foreign_key_constraint(:profile_id)
  end

  defp validate_times(changeset) do
    override_type = get_field(changeset, :override_type)
    start_time = get_field(changeset, :start_time)
    end_time = get_field(changeset, :end_time)

    if override_type == "custom_hours" do
      changeset
      |> validate_required([:start_time, :end_time], message: "are required for custom hours")
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

  defp validate_reason(changeset) do
    validate_length(changeset, :reason, max: 100, message: "must be 100 characters or less")
  end

  @spec override_types() :: [String.t()]
  def override_types, do: @override_types
end
