defmodule Tymeslot.Meetings.UniqueInvitation do
  @moduledoc """
  The single-use invitation index, `meetings_invitation_id_occupying_index`:
  at most one meeting carrying an invitation's id may hold a slot (confirmed,
  pending, awaiting payment or awaiting approval).

  Every `MeetingSchema` changeset that can write a meeting into a slot-holding
  status declares it (`constrain/1`), so a second live booking on one
  invitation, or a meeting brought back after its invitation was booked
  again, comes back as a changeset error rather than a raised
  `Ecto.ConstraintError`. The same call declares the invitation foreign key,
  so an invitation deleted after the booking's pre-check is an error too
  (`unavailable?/1` covers both). Split out of `MeetingSchema` to keep it
  inside the size limit, as `Tymeslot.Meetings.UniqueSlot` is.
  """

  import Ecto.Changeset, only: [cast: 3, foreign_key_constraint: 2, unique_constraint: 3]

  alias Tymeslot.Meetings.UniqueIndex

  @constraint :meetings_invitation_id_occupying_index

  @doc "Declares the index and the invitation foreign key on a meeting changeset."
  @spec constrain(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def constrain(changeset) do
    changeset
    |> foreign_key_constraint(:invitation_id)
    |> unique_constraint(:invitation_id, name: @constraint)
  end

  @doc """
  Casts `:invitation_id` on a new meeting only: a booking records the
  invitation it used, and nothing later may rewrite which one that was.
  """
  @spec cast_on_insert(Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def cast_on_insert(%Ecto.Changeset{data: %{__meta__: %{state: :built}}} = changeset, attrs),
    do: cast(changeset, attrs, [:invitation_id])

  def cast_on_insert(changeset, _attrs), do: changeset

  @doc """
  True when a changeset's error is a violation of the index: the invitation
  is already held by another live booking, not invalid input.
  """
  @spec violation?(Ecto.Changeset.t()) :: boolean()
  def violation?(changeset), do: UniqueIndex.violated?(changeset, @constraint)

  @doc """
  True when the write was refused because the invitation cannot be booked: held
  by another live booking (`violation?/1`), or deleted since the pre-check.
  """
  @spec unavailable?(Ecto.Changeset.t()) :: boolean()
  def unavailable?(%Ecto.Changeset{errors: errors} = changeset) do
    violation?(changeset) or
      Enum.any?(errors, fn
        {:invitation_id, {_message, opts}} -> opts[:constraint] == :foreign
        _other -> false
      end)
  end
end
