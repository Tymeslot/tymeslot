defmodule Tymeslot.Meetings.UniqueSlot do
  @moduledoc """
  The organiser's unique slot index, `(organizer_user_id, start_time)` over the
  rows that hold a slot (confirmed, awaiting approval or awaiting email
  verification, and not voided by a reschedule request), which every `MeetingSchema` changeset that can write a
  slot-holding status declares (`constrain/1`).

  Split out of `MeetingSchema` to keep it inside the size limit; the schema
  delegates `unique_slot_violation?/1` here.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Ecto.Changeset, only: [unique_constraint: 3]

  alias Tymeslot.Meetings.UniqueIndex

  @constraint :unique_confirmed_meeting_per_organizer_at_time

  @doc """
  Declares the index on a meeting changeset. The message names no meeting:
  the row holding the slot may be one the host cannot see yet (awaiting its
  attendee's email verification), and the flows that answer a violation
  map it to a lost race rather than showing this message.
  """
  @spec constrain(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def constrain(changeset) do
    unique_constraint(changeset, [:organizer_user_id, :start_time],
      name: @constraint,
      message:
        dgettext_noop(
          "errors",
          "This time is no longer available. Please choose another time."
        )
    )
  end

  @doc """
  True when a changeset's error is a violation of the index: a lost race for
  the slot against a writer that committed first, not invalid input.

  Group seat booking retries on it by joining the winner's meeting, and the
  booking flow answers it as the slot being taken.
  """
  @spec violation?(Ecto.Changeset.t()) :: boolean()
  def violation?(changeset), do: UniqueIndex.violated?(changeset, @constraint)
end
