defmodule Tymeslot.Meetings.SeatLookup do
  @moduledoc """
  Loads a group-booking seat by its management token and confirms it is
  still live, and whether it can still be given up.

  The single source of truth for "does this token still point at a seat a
  visitor may act on". A participant who cancelled or moved their seat
  (`:already_cancelled`) and a meeting the host cancelled
  (`:meeting_cancelled`) are both dead ends, told apart so the page can say
  which. Used by `TymeslotWeb.SeatController` (the public cancel/reschedule
  pages), `Tymeslot.Bookings.CancelSeat` and
  `Tymeslot.Scheduling.ThemeFlow.seat_move_context/2` (dropping a spent
  token from a booking form).

  A seat whose host is pending account deletion is `:not_found`: that
  host's meetings are about to go, so their links act as if unknown.
  """

  alias Tymeslot.Auth
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.ParticipantSchema

  @type seat :: %{participant: ParticipantSchema.t(), meeting: MeetingSchema.t()}
  @type dead_end :: :not_found | :already_cancelled | :meeting_cancelled

  @typedoc """
  Why a live seat can no longer be given up online: its meeting is under way
  (`:meeting_started`) or over (`:meeting_past`). Any other refusal from
  `Tymeslot.Bookings.Policy` passes through as it stands.
  """
  @type refusal :: :meeting_started | :meeting_past | Policy.cancel_refusal()

  @spec fetch_live_seat(String.t()) :: {:ok, seat()} | {:error, dead_end()}
  def fetch_live_seat(token) when is_binary(token) do
    with {:ok, participant} <- ParticipantQueries.get_by_token(token),
         {:ok, meeting} <- MeetingQueries.get_meeting(participant.meeting_id),
         :ok <- ensure_host_active(meeting) do
      live_seat(participant, meeting)
    else
      _error -> {:error, :not_found}
    end
  end

  def fetch_live_seat(_token), do: {:error, :not_found}

  @doc """
  The organiser whose meeting the seat behind `token` is on, live or not.

  A link that can no longer be used still says whose booking page to send
  the visitor to for a new time; only a token naming no seat at all says
  nothing.
  """
  @spec organizer_user_id(String.t()) :: {:ok, integer()} | {:error, :not_found}
  def organizer_user_id(token) when is_binary(token) do
    with {:ok, participant} <- ParticipantQueries.get_by_token(token),
         {:ok, %{organizer_user_id: user_id} = meeting} when is_integer(user_id) <-
           MeetingQueries.get_meeting(participant.meeting_id),
         :ok <- ensure_host_active(meeting) do
      {:ok, user_id}
    else
      _error -> {:error, :not_found}
    end
  end

  @doc """
  A live seat its participant may still cancel. The same checks
  `Tymeslot.Bookings.CancelSeat` makes before it cancels, so the cancel
  landing page refuses exactly what the cancellation would.
  """
  @spec fetch_cancellable_seat(String.t()) :: {:ok, seat()} | {:error, dead_end() | refusal()}
  def fetch_cancellable_seat(token) do
    with {:ok, %{meeting: meeting} = seat} <- fetch_live_seat(token),
         :ok <- cancellable(meeting) do
      {:ok, seat}
    end
  end

  # Whether `meeting` still lets a participant give up their seat, with the
  # policy's refusals for a meeting that has started or ended named for the
  # seat pages.
  defp cancellable(meeting) do
    case Policy.can_cancel_meeting?(meeting) do
      :ok -> :ok
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  defp refusal({:not_cancellable, :started}), do: :meeting_started
  defp refusal({:not_cancellable, state}) when state in [:completed, :past], do: :meeting_past
  defp refusal(reason), do: reason

  defp ensure_host_active(%{organizer_user_id: user_id}) when is_integer(user_id) do
    if Auth.deletion_pending?(user_id), do: {:error, :not_found}, else: :ok
  end

  defp ensure_host_active(_meeting), do: :ok

  defp live_seat(participant, meeting) do
    cond do
      not ParticipantSchema.live?(participant) -> {:error, :already_cancelled}
      meeting.status == "cancelled" -> {:error, :meeting_cancelled}
      true -> {:ok, %{participant: participant, meeting: meeting}}
    end
  end
end
