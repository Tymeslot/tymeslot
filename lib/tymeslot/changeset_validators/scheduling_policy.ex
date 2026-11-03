defmodule Tymeslot.ChangesetValidators.SchedulingPolicy do
  @moduledoc """
  Shared changeset validator for the scheduling rules: both buffers, the
  minimum notice and the booking window.

  The same four columns exist on `availability_schedules` (the rules a
  schedule sets) and `meeting_types` (a meeting type's overrides of them), so
  one bound applies to both. `nil` passes untouched; on a meeting type it means
  "use the schedule's value", and a schedule's columns are `NOT NULL` anyway.
  """

  import Ecto.Changeset

  alias Tymeslot.Validation.Constraints

  @doc "Validates the four scheduling rule fields against their `Constraints` bounds."
  @spec validate_scheduling_policy(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_scheduling_policy(changeset) do
    changeset
    |> validate_number(:buffer_before_minutes, Constraints.buffer_before_minutes_opts())
    |> validate_number(:buffer_after_minutes, Constraints.buffer_after_minutes_opts())
    |> validate_number(:min_advance_hours, Constraints.min_advance_hours_opts())
    |> validate_number(:advance_booking_days, Constraints.advance_booking_days_opts())
  end
end
