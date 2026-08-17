defmodule Tymeslot.Availability.AvailabilityScheduleSchema do
  @moduledoc """
  A named availability schedule owned by a profile.

  A schedule is the aggregate root for "when can this be booked": it owns a
  weekly pattern (`Tymeslot.Availability.WeeklyAvailabilitySchema` rows and
  their breaks), its date overrides, and the scheduling policy applied to any
  meeting type that uses it.

  Every profile has exactly one default schedule, enforced by a partial unique
  index. A meeting type with no `availability_schedule_id` uses that default.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Validation.Constraints

  @type t :: %__MODULE__{
          id: integer() | nil,
          profile_id: integer() | nil,
          name: String.t() | nil,
          is_default: boolean(),
          buffer_minutes: integer(),
          min_advance_hours: integer(),
          advance_booking_days: integer(),
          profile: ProfileSchema.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @name_max_length 60

  schema "availability_schedules" do
    field(:name, :string)
    field(:is_default, :boolean, default: false)
    # These three mirror `Constraints.scheduling_policy_defaults/0` and the
    # column defaults in the migration. They stay literal here so the schema
    # carries no compile-time dependency on `Constraints`; the three are pinned
    # together by `AvailabilityScheduleSchemaTest`.
    field(:buffer_minutes, :integer, default: 15)
    field(:min_advance_hours, :integer, default: 3)
    field(:advance_booking_days, :integer, default: 90)

    belongs_to(:profile, ProfileSchema)

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [
      :profile_id,
      :name,
      :is_default,
      :buffer_minutes,
      :min_advance_hours,
      :advance_booking_days
    ])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:profile_id, :name])
    |> validate_length(:name, min: 1, max: @name_max_length)
    |> validate_number(:buffer_minutes, Constraints.buffer_minutes_opts())
    |> validate_number(:min_advance_hours, Constraints.min_advance_hours_opts())
    |> validate_number(:advance_booking_days, Constraints.advance_booking_days_opts())
    |> unique_constraint(:name, name: :availability_schedules_profile_id_name_index)
    |> unique_constraint(:is_default, name: :availability_schedules_one_default_per_profile)
    |> foreign_key_constraint(:profile_id)
  end

  @doc """
  Changeset for the three scheduling policy fields only.

  Used by the availability page's policy card, which must never be able to
  rename a schedule or change which one is the default.
  """
  @spec policy_changeset(t(), map()) :: Ecto.Changeset.t()
  def policy_changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [:buffer_minutes, :min_advance_hours, :advance_booking_days])
    |> validate_number(:buffer_minutes, Constraints.buffer_minutes_opts())
    |> validate_number(:min_advance_hours, Constraints.min_advance_hours_opts())
    |> validate_number(:advance_booking_days, Constraints.advance_booking_days_opts())
  end

  @doc """
  Maximum length of a schedule name, exposed for the form's `maxlength` attribute.
  """
  @spec name_max_length() :: pos_integer()
  def name_max_length, do: @name_max_length
end
