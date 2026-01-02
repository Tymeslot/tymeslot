defmodule Tymeslot.DatabaseSchemas.AvailabilityBreakSchema do
  @moduledoc """
  Schema for breaks within a day's availability.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.DatabaseQueries.AvailabilityBreakQueries
  alias Tymeslot.DatabaseSchemas.WeeklyAvailabilitySchema

  @type t :: %__MODULE__{
          id: integer() | nil,
          weekly_availability_id: integer() | nil,
          start_time: Time.t() | nil,
          end_time: Time.t() | nil,
          label: String.t() | nil,
          sort_order: integer(),
          weekly_availability: WeeklyAvailabilitySchema.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "availability_breaks" do
    field(:start_time, :time)
    field(:end_time, :time)
    field(:label, :string)
    field(:sort_order, :integer, default: 0)

    belongs_to(:weekly_availability, WeeklyAvailabilitySchema)

    timestamps()
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(break, attrs) do
    break
    |> cast(attrs, [:weekly_availability_id, :start_time, :end_time, :label, :sort_order])
    |> validate_required([:weekly_availability_id, :start_time, :end_time])
    |> validate_time_order()
    |> validate_within_work_hours()
    |> validate_label()
    |> foreign_key_constraint(:weekly_availability_id)
  end

  defp validate_time_order(changeset) do
    start_time = get_field(changeset, :start_time)
    end_time = get_field(changeset, :end_time)

    if start_time && end_time && Time.compare(start_time, end_time) != :lt do
      add_error(changeset, :end_time, "must be after start time")
    else
      changeset
    end
  end

  defp validate_within_work_hours(changeset) do
    with id when not is_nil(id) <- get_field(changeset, :weekly_availability_id),
         start_time when not is_nil(start_time) <- get_field(changeset, :start_time),
         end_time when not is_nil(end_time) <- get_field(changeset, :end_time),
         {wa_start, wa_end} <- AvailabilityBreakQueries.get_work_hours(id) do
      changeset =
        if wa_start && Time.compare(start_time, wa_start) == :lt do
          add_error(changeset, :start_time, "must be within work hours")
        else
          changeset
        end

      if wa_end && Time.compare(end_time, wa_end) == :gt do
        add_error(changeset, :end_time, "must be within work hours")
      else
        changeset
      end
    else
      _ -> changeset
    end
  end

  defp validate_label(changeset) do
    validate_length(changeset, :label, max: 50, message: "must be 50 characters or less")
  end
end
