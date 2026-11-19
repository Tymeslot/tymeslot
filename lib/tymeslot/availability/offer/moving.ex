defmodule Tymeslot.Availability.Offer.Moving do
  @moduledoc """
  What a reschedule page's request to `Tymeslot.Availability.Offer` is
  moving: the meeting its offered times leave out, and, for a session of a
  series, how far past the booking window those times may reach.
  """

  alias Tymeslot.Bookings.{Orchestrator, RescheduleSeat}
  alias Tymeslot.Scheduling.{RescheduleContext, SeatMoveContext}

  @doc """
  The meeting a reschedule page is moving, once
  `Orchestrator.get_meeting_for_reschedule/2` proves it is this organiser's
  and still movable (the lookup the submit's own flow relies on); nil for
  anything else. The link parameter is visitor input, so it is never used
  unverified.

  The whole record, not just its uid, because the page has to leave the
  meeting out of two different counts: the host's booking limits, keyed on
  the uid, and the events read back from their connected calendar, where the
  meeting appears as the provider event Tymeslot wrote and is matched by
  whichever identifier that provider family preserves.

  A seat move vacates its meeting only when the mover is its last seat;
  `RescheduleSeat.vacated_meeting/2` is the submit's own rule for that.
  """
  @spec meeting(map()) :: struct() | nil
  def meeting(%{reschedule_seat_token: token, profile: %{user_id: user_id}} = request)
      when is_binary(token) and is_integer(user_id) do
    case request[:seat_move] do
      %SeatMoveContext{token: ^token, seat: seat} -> RescheduleSeat.vacated_meeting(seat, user_id)
      _not_loaded -> RescheduleSeat.vacated_meeting(token, user_id)
    end
  end

  # The page's own load of the meeting, when it names the same meeting for
  # the same organiser; a fetch then needs no lookup of its own.
  def meeting(%{
        reschedule_uid: uid,
        reschedule: %RescheduleContext{
          uid: uid,
          meeting: %{organizer_user_id: user_id} = meeting
        },
        profile: %{user_id: user_id}
      })
      when is_binary(uid) and is_integer(user_id),
      do: meeting

  def meeting(%{reschedule_uid: uid, profile: %{user_id: user_id}})
      when is_binary(uid) and is_integer(user_id) do
    case Orchestrator.get_meeting_for_reschedule(uid, user_id) do
      {:ok, meeting} -> meeting
      {:error, _not_movable} -> nil
    end
  end

  def meeting(_request), do: nil

  @doc "The uid of `meeting/1`'s answer, or nil."
  @spec uid(map() | nil) :: String.t() | nil
  def uid(nil), do: nil
  def uid(%{uid: uid}), do: uid

  @doc """
  `request` with its `:window_until` set to how far a series session it
  moves may reach (`Tymeslot.BookingSeries.window_until/1`, settled when
  the page loaded what it moves), when it moves one and names no reach of
  its own. A context is read only when it is the one the request's link
  names, as `meeting/1` reads it.
  """
  @spec with_reach(map()) :: map()
  def with_reach(%{window_until: %Date{}} = request), do: request

  def with_reach(request) do
    case reach(request) do
      %Date{} = until -> Map.put(request, :window_until, until)
      nil -> request
    end
  end

  defp reach(%{reschedule_seat_token: token, seat_move: %SeatMoveContext{token: token} = context})
       when is_binary(token),
       do: context.window_until

  defp reach(%{reschedule_uid: uid, reschedule: %RescheduleContext{uid: uid} = context})
       when is_binary(uid),
       do: context.window_until

  defp reach(_request), do: nil
end
