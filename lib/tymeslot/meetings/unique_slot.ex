defmodule Tymeslot.Meetings.UniqueSlot do
  @moduledoc """
  The organiser's unique slot index, `(organizer_user_id, start_time)` over the
  rows that hold a slot, which `MeetingSchema`'s changesets declare.

  Split out of `MeetingSchema` to keep it inside the size limit; the schema
  delegates `unique_slot_violation?/1` here.
  """

  @constraint :unique_confirmed_meeting_per_organizer_at_time

  @doc "The index's name, as the changesets' `unique_constraint/3` declares it."
  @spec constraint() :: atom()
  def constraint, do: @constraint

  @doc """
  True when a changeset's error is a violation of the index: a lost race for
  the slot against a writer that committed first, not invalid input.

  Group seat booking retries on it by joining the winner's meeting, and the
  booking flow answers it as the slot being taken.
  """
  @spec violation?(Ecto.Changeset.t()) :: boolean()
  def violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, error_opts}} ->
      error_opts[:constraint] == :unique and
        to_string(error_opts[:constraint_name] || "") == Atom.to_string(@constraint)
    end)
  end
end
