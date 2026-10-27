defmodule Tymeslot.Scheduling.SeatMoveContext do
  @moduledoc """
  The live group seat a seat-move page is moving, loaded once for the page by
  `Tymeslot.Scheduling.ThemeFlow.seat_move_context/2` from the
  `reschedule_seat_token` its link carries, and what the page starts from that
  it decides.

  One load for all of it, so the time the date step says the spot is moving
  from, the meeting type the page is pinned to, the form's starting values and
  the meeting the offered times may leave out all describe the same seat. The
  submit checks the seat again whatever the page holds.

    * `:token` - the seat's management token.
    * `:seat` - the participant and the meeting their seat is on, as
      `Tymeslot.Meetings.fetch_live_seat/1` returns them.
    * `:start` - when the seat's meeting starts: the time the spot is moving
      from.
    * `:meeting_type` - the type of the seat's meeting, which the move is
      committed to; `nil` when that meeting is not the page's organiser's (a
      hand-edited username).
    * `:form_data` - the booking form's starting values: the participant's
      own details.
  """

  @enforce_keys [:token, :seat, :start, :form_data]
  defstruct [:token, :seat, :start, :meeting_type, :form_data]

  @type t :: %__MODULE__{
          token: String.t(),
          seat: %{participant: struct(), meeting: struct()},
          start: DateTime.t(),
          meeting_type: map() | nil,
          form_data: %{String.t() => String.t()}
        }

  @doc "The context for the live `seat` behind `token`, committed to `meeting_type`."
  @spec new(String.t(), %{participant: struct(), meeting: struct()}, map() | nil) :: t()
  def new(token, %{participant: participant, meeting: meeting} = seat, meeting_type) do
    %__MODULE__{
      token: token,
      seat: seat,
      start: meeting.start_time,
      meeting_type: meeting_type,
      form_data: %{
        "name" => participant.name,
        "email" => participant.email,
        "message" => participant.message || ""
      }
    }
  end
end
