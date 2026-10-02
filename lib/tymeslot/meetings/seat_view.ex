defmodule Tymeslot.Meetings.SeatView do
  @moduledoc """
  A group meeting as one of its seats: the shape webhooks, Slack and Telegram
  are handed, so that every seat reaches them as a booking of its own.

  A group meeting row has no attendee of its own; its people are its
  participant rows. The view overlays one participant onto the meeting
  through `Tymeslot.Meetings.Recipient.meeting_as_seen_by/2` (their details
  in `attendee_*`, their seat URLs), narrows a loaded `guests` list to the
  guests that participant invited, and records the seat in the virtual
  `seat` field: which participant it is, and how many seats were taken on
  the slot when the event fired.

  A cancelled seat on a meeting that is still on reads as cancelled, at the
  time the seat was given up: to an integration that seat is a booking, and
  the booking is off.

  The integration jobs carry only ids, so the dispatch side builds the view
  with `at_event/2` and the delivery side rebuilds it from the ids with
  `load/3`.
  """

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.Recipient

  @doc """
  The view of `meeting` as `participant`'s seat, with the seats taken on the
  slot counted now: for the moment an event about the seat fires.
  """
  @spec at_event(MeetingSchema.t(), ParticipantSchema.t()) :: MeetingSchema.t()
  def at_event(%MeetingSchema{} = meeting, %ParticipantSchema{} = participant),
    do: build(meeting, participant, ParticipantQueries.count_seats_taken(meeting.id))

  @doc """
  Rebuilds the view of a delivery job's seat from its participant id.

  The participant is loaded whether or not they have cancelled, since an
  event about a cancelled seat is about exactly that participant.
  `seats_taken` is the count the event fired with; `nil` counts again now.
  Returns `{:error, :not_found}` for a participant that does not exist or
  is not on this meeting.
  """
  @spec load(MeetingSchema.t(), binary(), non_neg_integer() | nil) ::
          {:ok, MeetingSchema.t()} | {:error, :not_found}
  def load(%MeetingSchema{id: meeting_id} = meeting, participant_id, seats_taken) do
    case ParticipantQueries.get(participant_id) do
      {:ok, %ParticipantSchema{meeting_id: ^meeting_id} = participant} ->
        {:ok, build(meeting, participant, seats_taken || count_now(meeting))}

      _missing_or_elsewhere ->
        {:error, :not_found}
    end
  end

  @doc "The participant id of the seat a view is of, or `nil` for any other meeting."
  @spec participant_id(map()) :: binary() | nil
  def participant_id(%{seat: %{participant_id: participant_id}}), do: participant_id
  def participant_id(_meeting), do: nil

  @doc "The seats taken when the event about a seat view fired, or `nil` for any other meeting."
  @spec seats_taken(map()) :: non_neg_integer() | nil
  def seats_taken(%{seat: %{seats_taken: seats_taken}}), do: seats_taken
  def seats_taken(_meeting), do: nil

  defp build(meeting, participant, seats_taken) do
    seen = Recipient.meeting_as_seen_by(meeting, participant)

    put_seat_status(
      %{
        seen
        | seat: %{participant_id: participant.id, seats_taken: seats_taken},
          guests: seat_guests(seen.guests, participant.id)
      },
      participant
    )
  end

  defp count_now(meeting), do: ParticipantQueries.count_seats_taken(meeting.id)

  defp seat_guests(guests, participant_id) when is_list(guests),
    do: Enum.filter(guests, &(&1.participant_id == participant_id))

  defp seat_guests(not_loaded, _participant_id), do: not_loaded

  defp put_seat_status(meeting, %ParticipantSchema{cancelled_at: nil}), do: meeting
  defp put_seat_status(%MeetingSchema{status: "cancelled"} = meeting, _participant), do: meeting

  defp put_seat_status(meeting, %ParticipantSchema{cancelled_at: cancelled_at}),
    do: %{meeting | status: "cancelled", cancelled_at: cancelled_at}
end
