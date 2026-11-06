defmodule Tymeslot.Meetings.UniqueInvitation do
  @moduledoc """
  The single-use invitation index, `meetings_invitation_id_occupying_index`:
  at most one meeting carrying an invitation's id may hold a slot (confirmed,
  pending, awaiting payment or awaiting approval).

  Every `MeetingSchema` changeset that can write a meeting into a slot-holding
  status declares it (`constrain/1`), so a second live booking on one
  invitation, or a meeting brought back after its invitation was booked
  again, comes back as a changeset error rather than a raised
  `Ecto.ConstraintError`. Split out of `MeetingSchema` to keep it inside the
  size limit, as `Tymeslot.Meetings.UniqueSlot` is.
  """

  import Ecto.Changeset, only: [unique_constraint: 3]

  @constraint :meetings_invitation_id_occupying_index

  @doc "Declares the index on a meeting changeset."
  @spec constrain(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def constrain(changeset), do: unique_constraint(changeset, :invitation_id, name: @constraint)

  @doc """
  True when a changeset's error is a violation of the index: the invitation
  is already held by another live booking, not invalid input.
  """
  @spec violation?(Ecto.Changeset.t()) :: boolean()
  def violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:invitation_id, {_message, error_opts}} ->
        error_opts[:constraint] == :unique and
          to_string(error_opts[:constraint_name] || "") == Atom.to_string(@constraint)

      _other ->
        false
    end)
  end
end
