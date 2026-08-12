defmodule Tymeslot.Meetings.SeatLookup do
  @moduledoc """
  Loads a group-booking seat by its management token and confirms it is
  still live.

  The single source of truth for "does this token still point at a seat a
  visitor may act on": a cancelled participant, or a meeting whose own
  status has moved to `"cancelled"`, are both dead ends. Used by
  `TymeslotWeb.SeatController` (the public cancel/reschedule landing pages)
  and `Tymeslot.Scheduling.ThemeFlow.live_seat_token?/1` (dropping a spent
  token from a booking form).
  """

  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.ParticipantSchema

  @spec fetch_live_seat(String.t()) ::
          {:ok, %{participant: ParticipantSchema.t(), meeting: MeetingSchema.t()}}
          | {:error, :not_found | :already_cancelled}
  def fetch_live_seat(token) when is_binary(token) do
    with {:ok, participant} <- ParticipantQueries.get_by_token(token),
         {:ok, meeting} <- MeetingQueries.get_meeting(participant.meeting_id) do
      live_seat(participant, meeting)
    else
      _error -> {:error, :not_found}
    end
  end

  def fetch_live_seat(_token), do: {:error, :not_found}

  defp live_seat(participant, meeting) do
    if ParticipantSchema.live?(participant) and meeting.status != "cancelled" do
      {:ok, %{participant: participant, meeting: meeting}}
    else
      {:error, :already_cancelled}
    end
  end
end
