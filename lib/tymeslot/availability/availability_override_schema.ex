defmodule Tymeslot.Availability.AvailabilityOverrideSchema do
  @moduledoc """
  Schema for date-specific availability overrides.

  `unavailable`, `custom_hours` and `available` each say what a schedule's
  date is instead of its weekly hours, one per schedule and date.
  `extra_hours` adds a time on a date besides whatever else is open then;
  a date may hold several (see `Tymeslot.Availability.ExtraAvailability`).
  """
  use Gettext, backend: TymeslotWeb.Gettext
  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Availability.AvailabilityScheduleSchema
  alias Tymeslot.ChangesetValidators.AvailabilityWindow
  alias Tymeslot.Validation.Constraints

  @typedoc "What an override says about its date."
  @type override_type :: :unavailable | :custom_hours | :available | :extra_hours

  @type t :: %__MODULE__{
          id: integer() | nil,
          schedule_id: integer() | nil,
          date: Date.t() | nil,
          override_type: override_type() | nil,
          start_time: Time.t() | nil,
          end_time: Time.t() | nil,
          ends_next_day: boolean(),
          reason: String.t() | nil,
          schedule: AvailabilityScheduleSchema.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "availability_overrides" do
    field(:date, :date)

    field(:override_type, Ecto.Enum,
      values: [:unavailable, :custom_hours, :available, :extra_hours]
    )

    field(:start_time, :time)
    field(:end_time, :time)
    field(:ends_next_day, :boolean, default: false)
    field(:reason, :string)

    belongs_to(:schedule, AvailabilityScheduleSchema)

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(override, attrs) do
    override
    |> cast(attrs, [
      :schedule_id,
      :date,
      :override_type,
      :start_time,
      :end_time,
      :ends_next_day,
      :reason
    ])
    |> validate_required([:schedule_id, :date, :override_type])
    |> AvailabilityWindow.normalise_next_day(:availability_overrides_next_day_end_check)
    |> validate_times()
    |> validate_reason()
    |> unique_constraint([:schedule_id, :date])
    |> foreign_key_constraint(:schedule_id)
  end

  defp validate_times(changeset) do
    override_type = get_field(changeset, :override_type)

    if override_type in [:custom_hours, :extra_hours] do
      changeset
      |> validate_required([:start_time, :end_time],
        message: dgettext_noop("errors", "are required for custom hours")
      )
      |> AvailabilityWindow.validate_window()
    else
      changeset
    end
  end

  defp validate_reason(changeset) do
    max = Constraints.override_reason_max_length()

    validate_length(changeset, :reason,
      max: max,
      message: dgettext("errors", "must be %{max} characters or less", max: max)
    )
  end
end
