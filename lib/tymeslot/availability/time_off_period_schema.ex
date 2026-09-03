defmodule Tymeslot.Availability.TimeOffPeriodSchema do
  @moduledoc """
  A stretch of time the profile's owner is away and takes no bookings.

  Unlike an override or a break, a period hangs off the profile rather than off
  one availability schedule, so it applies to every schedule and every meeting
  type the profile owns. See the creating migration for why.

  The row describes one continuous interval in the owner's timezone:
  `starts_on` at `start_time` through `ends_on` at `end_time`, both dates
  inclusive. Either time may be null, meaning "from the start of that day" and
  "to the end of that day" respectively; whole-day time off is the case where
  both are null. `Tymeslot.Availability.TimeOff` turns a row into the window it
  blocks on a given date, and is the only place that reading is made.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Validation.Constraints

  @type t :: %__MODULE__{
          id: integer() | nil,
          profile_id: integer() | nil,
          starts_on: Date.t() | nil,
          ends_on: Date.t() | nil,
          start_time: Time.t() | nil,
          end_time: Time.t() | nil,
          label: String.t() | nil,
          profile: ProfileSchema.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "availability_time_off_periods" do
    field(:starts_on, :date)
    field(:ends_on, :date)
    field(:start_time, :time)
    field(:end_time, :time)
    field(:label, :string)

    belongs_to(:profile, ProfileSchema)

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(period, attrs) do
    period
    |> cast(blank_to_nil(attrs), [
      :profile_id,
      :starts_on,
      :ends_on,
      :start_time,
      :end_time,
      :label
    ])
    |> update_change(:label, &trim_to_nil/1)
    |> validate_required([:profile_id, :starts_on, :ends_on])
    |> validate_date_order()
    |> validate_time_order_on_single_day()
    |> validate_label()
    |> foreign_key_constraint(:profile_id)
  end

  # `cast/4` reads "" as *absent*, which on an update leaves the stored value in
  # place. The form submits "" for both "All day" and a cleared note, and both
  # have to clear the column rather than keep whatever was there before, so the
  # blanks are turned into explicit nils before cast ever sees them.
  defp blank_to_nil(attrs) do
    Map.new(attrs, fn
      {key, ""} -> {key, nil}
      pair -> pair
    end)
  end

  defp trim_to_nil(nil), do: nil

  defp trim_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp validate_date_order(changeset) do
    with %Date{} = starts_on <- get_field(changeset, :starts_on),
         %Date{} = ends_on <- get_field(changeset, :ends_on),
         :lt <- Date.compare(ends_on, starts_on) do
      add_error(changeset, :ends_on, "must not be before the start date")
    else
      _in_order -> changeset
    end
  end

  # Only meaningful when both times land on the same day. Across a range the
  # two sit on different dates, so an end time earlier in the clock than the
  # start time is the ordinary "away from Friday afternoon until Monday
  # morning" case rather than an error.
  defp validate_time_order_on_single_day(changeset) do
    starts_on = get_field(changeset, :starts_on)
    ends_on = get_field(changeset, :ends_on)
    start_time = get_field(changeset, :start_time)
    end_time = get_field(changeset, :end_time)

    if starts_on && starts_on == ends_on && start_time && end_time &&
         Time.compare(start_time, end_time) != :lt do
      add_error(changeset, :end_time, "must be after the start time")
    else
      changeset
    end
  end

  defp validate_label(changeset) do
    max = Constraints.time_off_label_max_length()
    validate_length(changeset, :label, max: max, message: "must be #{max} characters or less")
  end
end
