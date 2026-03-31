defmodule Tymeslot.ChangesetValidators.TimeOrder do
  @moduledoc """
  Shared changeset validator for time ordering constraints.

  Handles both `Time` and `DateTime` comparisons. Used by availability
  schemas and meeting schemas to enforce that end times follow start times.
  """

  import Ecto.Changeset

  @spec validate_time_order(Ecto.Changeset.t(), atom(), atom(), keyword()) ::
          Ecto.Changeset.t()
  def validate_time_order(changeset, start_field, end_field, opts \\ []) do
    start_time = get_field(changeset, start_field)
    end_time = get_field(changeset, end_field)
    message = Keyword.get(opts, :message, "must be after start time")
    compare_mod = if match?(%DateTime{}, start_time), do: DateTime, else: Time

    if start_time && end_time && compare_mod.compare(start_time, end_time) != :lt do
      add_error(changeset, end_field, message)
    else
      changeset
    end
  end
end
