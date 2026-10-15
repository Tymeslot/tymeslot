defmodule Tymeslot.ChangesetValidators.AvailabilityWindow do
  @moduledoc """
  Shared changeset validator for a day's availability window: `:start_time`,
  `:end_time` and `:ends_next_day`.

  Weekly windows (`weekly_availability`) and a date override's custom hours
  (`availability_overrides`) hold the same three columns under the same
  next-day check constraint; this module keeps their rules in one place.
  What makes a window valid is `Tymeslot.Availability.Window.valid?/3`.
  """

  import Ecto.Changeset

  alias Tymeslot.Availability.Window

  @next_day_message "must be at or before the start time when the hours end the next day"

  @doc """
  Settles `:ends_next_day` to a boolean and attaches the table's next-day
  check constraint (`constraint`) to `:end_time`.

  A row without both times is never flagged, so clearing a day's hours
  cannot trip the constraint, and an explicit `nil` reads as `false` rather
  than reaching the column's `NOT NULL`.
  """
  @spec normalise_next_day(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def normalise_next_day(changeset, constraint) do
    current = get_field(changeset, :ends_next_day)
    flagged? = current == true and has_hours?(changeset)

    changeset =
      if current == flagged?,
        do: changeset,
        else: put_change(changeset, :ends_next_day, flagged?)

    check_constraint(changeset, :end_time, name: constraint, message: @next_day_message)
  end

  @doc """
  Checks that the times and flag make a valid window: a same-day end after
  the start, or a next-day end at or before it. Missing times are left to the
  caller's required-field rule.
  """
  @spec validate_window(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_window(changeset) do
    start_time = get_field(changeset, :start_time)
    end_time = get_field(changeset, :end_time)
    ends_next_day = get_field(changeset, :ends_next_day) == true

    cond do
      is_nil(start_time) or is_nil(end_time) -> changeset
      Window.valid?(start_time, end_time, ends_next_day) -> changeset
      ends_next_day -> add_error(changeset, :end_time, @next_day_message)
      true -> add_error(changeset, :end_time, "must be after start time")
    end
  end

  defp has_hours?(changeset),
    do:
      not is_nil(get_field(changeset, :start_time)) and
        not is_nil(get_field(changeset, :end_time))
end
