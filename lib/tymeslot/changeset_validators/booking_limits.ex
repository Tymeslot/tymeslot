defmodule Tymeslot.ChangesetValidators.BookingLimits do
  @moduledoc """
  Shared changeset validator for the booking-limit field trio
  (`max_bookings_per_day/week/month`).

  The same three columns exist on `meeting_types` (per-type limits) and
  `profiles` (account-wide limits); this module keeps their validation and
  check-constraint wiring in one place. `nil` means "no limit" and passes
  validation untouched.
  """

  import Ecto.Changeset

  alias Tymeslot.Validation.Constraints

  @fields Constraints.booking_limit_fields()

  # Constraint-name atoms are created here at compile time, never at runtime.
  @constraint_names Map.new([:meeting_types, :profiles], fn table ->
                      {table, Map.new(@fields, &{&1, :"#{table}_#{&1}_positive"})}
                    end)

  @doc """
  Validates the three limit fields against `Constraints.booking_limit_opts/0`
  and attaches the `<table>_<field>_positive` check constraints.
  """
  @spec validate_booking_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_booking_limits(changeset, table) do
    constraint_names = Map.fetch!(@constraint_names, table)

    Enum.reduce(@fields, changeset, fn field, acc ->
      acc
      |> validate_number(field, Constraints.booking_limit_opts())
      |> check_constraint(field, name: Map.fetch!(constraint_names, field))
    end)
  end
end
