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
  use Gettext, backend: TymeslotWeb.Gettext

  import Ecto.Changeset

  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Validation.Constraints

  # Registered in both forms so the extractor writes a plural entry into the
  # `errors` domain. `Forms.translate_error/1` sends any message carrying a
  # `:count` through `dngettext/5`, which reads every form off the one msgid,
  # the way Ecto's own counted messages are read.
  @horizon_message elem(
                     dngettext_noop(
                       "errors",
                       "must be within %{count} years",
                       "must be within %{count} years"
                     ),
                     0
                   )

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

  @doc """
  Builds the changeset for a period.

  `opts` must carry `:today`, the owner's current date: a period may not be
  placed on days that have already gone, nor end further ahead than
  `Constraints.time_off_last_end_date/1`. The caller supplies it because only
  the caller knows whose timezone "today" is read in.

  `profile_id` is not cast: it is set on the struct by whoever creates the
  row, so no submitted attrs can move a period onto another profile.
  """
  @spec changeset(t(), map(), keyword()) :: Ecto.Changeset.t()
  def changeset(period, attrs, opts) do
    today = Keyword.fetch!(opts, :today)

    period
    |> cast(blank_to_nil(attrs), [
      :starts_on,
      :ends_on,
      :start_time,
      :end_time,
      :label
    ])
    |> update_change(:label, &clean_label/1)
    |> validate_required([:profile_id, :starts_on, :ends_on])
    |> validate_not_in_past(:starts_on, today)
    |> validate_not_in_past(:ends_on, today)
    |> validate_within_horizon(:ends_on, today)
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

  # PostgreSQL rejects null bytes in text columns by raising, not with a
  # changeset error, so they are stripped here before the row is written.
  defp clean_label(nil), do: nil

  defp clean_label(value) do
    case value |> String.replace("\x00", "") |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # Only a date the submission actually changes is checked. A period already
  # under way keeps a first day in the past, and editing its note or moving its
  # last day must not trip over that; what is refused is placing either end on
  # a day that has already gone.
  defp validate_not_in_past(changeset, field, today) do
    validate_change(changeset, field, fn ^field, date ->
      if Date.compare(date, today) == :lt,
        do: [{field, dgettext_noop("errors", "must not be in the past")}],
        else: []
    end)
  end

  # A mistyped year is the only way a date this far out gets entered, and it
  # has no symptom: the row is valid, so every reader honours it and the
  # booking page simply offers nothing, for ever, without naming a cause.
  #
  # Only the last day is bounded. The first cannot outrun it without failing
  # `validate_date_order/1`, and one message on the field that was mistyped
  # reads better than two saying the same thing.
  #
  # Checked with `validate_change/3` for the reason `validate_not_in_past/3`
  # is: a stored period must stay editable, including its note alone, however
  # far out it already reaches.
  defp validate_within_horizon(changeset, field, today) do
    last_end_date = Constraints.time_off_last_end_date(today)

    validate_change(changeset, field, fn ^field, date ->
      if Date.after?(date, last_end_date),
        do: [{field, {@horizon_message, count: Constraints.time_off_max_years_ahead()}}],
        else: []
    end)
  end

  defp validate_date_order(changeset) do
    with %Date{} = starts_on <- get_field(changeset, :starts_on),
         %Date{} = ends_on <- get_field(changeset, :ends_on),
         :lt <- Date.compare(ends_on, starts_on) do
      add_error(changeset, :ends_on, dgettext_noop("errors", "must not be before the start date"))
    else
      _in_order -> changeset
    end
  end

  # Only meaningful when both times land on the same day. Across a range the
  # two sit on different dates, so an end time earlier in the clock than the
  # start time is the ordinary "away from Friday afternoon until Monday
  # morning" case rather than an error.
  #
  # A null time stands for its end of the day, so a single day that is "All
  # day" to begin with and back at 00:00 is refused too: it would be listed as
  # time off while blocking nothing.
  defp validate_time_order_on_single_day(changeset) do
    starts_on = get_field(changeset, :starts_on)
    ends_on = get_field(changeset, :ends_on)
    start_time = get_field(changeset, :start_time) || ~T[00:00:00]
    end_time = get_field(changeset, :end_time) || ~T[23:59:59]

    if starts_on && starts_on == ends_on && Time.compare(start_time, end_time) != :lt do
      add_error(changeset, :end_time, dgettext_noop("errors", "must be after the start time"))
    else
      changeset
    end
  end

  # Ecto's own length message, so the form translates it through the `errors`
  # domain with its plural forms; an interpolated custom one never could be.
  # Counted in codepoints, the unit the column's varchar limit is measured in:
  # graphemes would let a label of composed emoji pass here and then overflow
  # the column, raising on insert.
  defp validate_label(changeset) do
    validate_length(changeset, :label,
      max: Constraints.time_off_label_max_length(),
      count: :codepoints
    )
  end
end
