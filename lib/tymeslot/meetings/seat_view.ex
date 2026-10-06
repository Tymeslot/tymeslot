defmodule Tymeslot.Meetings.SeatView do
  @moduledoc """
  A group meeting as one of its seats: the shape webhooks, Slack and Telegram
  are handed, so that every seat reaches them as a booking of its own.

  A group meeting row has no attendee of its own; its people are its
  participant rows. The view overlays one participant onto the meeting
  through `Tymeslot.Meetings.Recipient.meeting_as_seen_by/2` (their details
  in `attendee_*`, their seat URLs), narrows a loaded `guests` list to the
  guests that participant invited, and records the seat in the virtual
  `seat` field: which participant it is, how many seats were taken on the
  slot when the event fired, and, for a seat a move created, the seat it
  replaced (`previous`).

  A cancelled seat on a meeting that is still on reads as cancelled, at the
  time the seat was given up: to an integration that seat is a booking, and
  the booking is off.

  The integration jobs carry only ids, so the dispatch side builds the view
  with `at_event/4` and the delivery side rebuilds it from the ids (and the
  event's snapshot) with `load/4`.
  """

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.Recipient

  @typedoc """
  The seat a move replaced: its participant row, the meeting it was on, and
  that meeting's start time.
  """
  @type previous :: %{seat_id: binary(), meeting_id: binary(), start_time: DateTime.t()}

  @doc """
  The view of `meeting` as `participant`'s seat, for the moment an event
  about the seat fires. `seats_taken` is the count on the slot then; the
  default counts it now. `previous` is the seat a move replaced, `nil` for
  any other event.
  """
  @spec at_event(
          MeetingSchema.t(),
          ParticipantSchema.t(),
          non_neg_integer() | nil,
          previous() | nil
        ) :: MeetingSchema.t()
  def at_event(
        %MeetingSchema{} = meeting,
        %ParticipantSchema{} = participant,
        seats_taken \\ nil,
        previous \\ nil
      ),
      do: build(meeting, participant, seats_taken || count_now(meeting), previous)

  @doc """
  The view of a group meeting as the seat its booker holds, found by the
  email address they booked with (a slot holds one live seat per address),
  or `nil` when that address holds no live seat on it.
  """
  @spec for_booker(MeetingSchema.t(), String.t() | nil) :: MeetingSchema.t() | nil
  def for_booker(%MeetingSchema{id: meeting_id} = meeting, email) when is_binary(email) do
    address = ParticipantSchema.normalize_email(email)

    case Enum.find(ParticipantQueries.list_live_for_meeting(meeting_id), &(&1.email == address)) do
      nil -> nil
      participant -> at_event(meeting, participant)
    end
  end

  def for_booker(%MeetingSchema{}, _email), do: nil

  @doc "The seat a move replaced, from the old seat and the meeting it was on."
  @spec previous(MeetingSchema.t(), ParticipantSchema.t()) :: previous()
  def previous(%MeetingSchema{} = old_meeting, %ParticipantSchema{} = old_participant) do
    %{
      seat_id: old_participant.id,
      meeting_id: old_meeting.id,
      start_time: old_meeting.start_time
    }
  end

  @doc """
  Rebuilds the view of a delivery job's seat from its participant id.

  The participant is loaded whether or not they have cancelled, since an
  event about a cancelled seat is about exactly that participant.
  `seats_taken` is the count the event fired with; `nil` counts again now.
  `previous` is the seat a move replaced, as the event recorded it.
  Returns `{:error, :not_found}` for a participant that does not exist or
  is not on this meeting.
  """
  @spec load(MeetingSchema.t(), binary(), non_neg_integer() | nil, previous() | nil) ::
          {:ok, MeetingSchema.t()} | {:error, :not_found}
  def load(%MeetingSchema{id: meeting_id} = meeting, participant_id, seats_taken, previous \\ nil) do
    case ParticipantQueries.get(participant_id) do
      {:ok, %ParticipantSchema{meeting_id: ^meeting_id} = participant} ->
        {:ok, at_event(meeting, participant, seats_taken, previous)}

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

  @doc "The seat a seat view's move replaced, or `nil` for any other view or meeting."
  @spec previous_seat(map()) :: previous() | nil
  def previous_seat(%{seat: %{previous: previous}}), do: previous
  def previous_seat(_meeting), do: nil

  defp build(meeting, participant, seats_taken, previous) do
    seen = Recipient.meeting_as_seen_by(meeting, participant)

    put_seat_status(
      %{
        seen
        | seat: %{participant_id: participant.id, seats_taken: seats_taken, previous: previous},
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
