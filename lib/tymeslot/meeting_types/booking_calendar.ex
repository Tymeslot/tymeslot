defmodule Tymeslot.MeetingTypes.BookingCalendar do
  @moduledoc """
  The calendar a meeting type books into must block availability, so a
  meeting-type write that names one makes it block first, in the same
  transaction and before the meeting type's own row is written: the
  integration's row is locked ahead of the meeting type's, the order
  `Tymeslot.Integrations.Calendar.Blocking` documents.
  """

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.Blocking
  alias Tymeslot.MeetingTypes.MeetingTypeQueries

  @doc """
  Makes the booking calendar `changeset` names block, when the write changes
  which calendar that is. Call it inside the meeting type's transaction,
  before the write. `{:ok, :promoted | :unchanged}`, or `{:error, reason}`
  to roll the write back.
  """
  @spec promote(Changeset.t()) :: {:ok, :promoted | :unchanged} | {:error, term()}
  def promote(%Changeset{} = changeset) do
    user_id = Changeset.get_field(changeset, :user_id)
    integration_id = Changeset.get_field(changeset, :calendar_integration_id)
    calendar_id = Changeset.get_field(changeset, :target_calendar_id)

    retargeted? =
      Changeset.changed?(changeset, :calendar_integration_id) or
        Changeset.changed?(changeset, :target_calendar_id)

    if retargeted? and is_integer(user_id) and is_integer(integration_id) and
         is_binary(calendar_id) do
      Blocking.promote_booking_target(user_id, integration_id, calendar_id)
    else
      {:ok, :unchanged}
    end
  end

  @doc """
  The calendars of the user's integration `calendar_integration_id` that
  their meeting types name as the calendar they book into.
  """
  @spec ids(integer(), integer()) :: [String.t()]
  def ids(user_id, calendar_integration_id),
    do: MeetingTypeQueries.target_calendar_ids(user_id, calendar_integration_id)

  @doc """
  `ids/2` for every integration of the user at once, keyed by integration id.
  """
  @spec ids_by_integration(integer()) :: %{integer() => [String.t()]}
  def ids_by_integration(user_id) do
    user_id
    |> MeetingTypeQueries.calendar_targets()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end
end
