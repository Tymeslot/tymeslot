defmodule Tymeslot.ChangesetValidators.SchedulingPolicy do
  @moduledoc """
  Shared changeset validator for the scheduling rules: both buffers, the
  minimum notice and the booking window.

  The same four columns exist on `availability_schedules` (the rules a
  schedule sets) and `meeting_types` (a meeting type's overrides of them), so
  one bound applies to both, and this module keeps their validation and
  check-constraint wiring in one place. `nil` passes untouched; on a meeting
  type it means "use the schedule's value", and a schedule's columns are
  `NOT NULL` anyway.
  """

  import Ecto.Changeset

  alias Tymeslot.Validation.Constraints

  @fields Constraints.scheduling_policy_fields()

  # The `<table>_<field>_range` check constraints each table carries.
  # `availability_schedules` has them on its buffers only; `meeting_types` on
  # all four. Constraint-name atoms are created here at compile time, never at
  # runtime.
  @constraint_names %{
    availability_schedules:
      Map.new(
        [:buffer_before_minutes, :buffer_after_minutes],
        &{&1, :"availability_schedules_#{&1}_range"}
      ),
    meeting_types: Map.new(@fields, &{&1, :"meeting_types_#{&1}_range"})
  }

  @doc """
  Validates the four scheduling rule fields against their `Constraints` bounds
  and attaches the table's `<table>_<field>_range` check constraints.
  """
  @spec validate_scheduling_policy(Ecto.Changeset.t(), :availability_schedules | :meeting_types) ::
          Ecto.Changeset.t()
  def validate_scheduling_policy(changeset, table) do
    changeset
    |> validate_number(:buffer_before_minutes, Constraints.buffer_before_minutes_opts())
    |> validate_number(:buffer_after_minutes, Constraints.buffer_after_minutes_opts())
    |> validate_number(:min_advance_hours, Constraints.min_advance_hours_opts())
    |> validate_number(:advance_booking_days, Constraints.advance_booking_days_opts())
    |> check_constraints(Map.fetch!(@constraint_names, table))
  end

  defp check_constraints(changeset, names) do
    Enum.reduce(names, changeset, fn {field, name}, acc ->
      check_constraint(acc, field, name: name)
    end)
  end
end
