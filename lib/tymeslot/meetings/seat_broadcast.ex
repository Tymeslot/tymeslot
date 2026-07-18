defmodule Tymeslot.Meetings.SeatBroadcast do
  @moduledoc """
  PubSub notifications for seat-count changes on group meeting types.

  Open booking pages subscribe to `topic/1` and refresh their slot lists in
  place when `{:seat_update, meeting_type_id}` arrives. Broadcast after the
  seat change has committed (booking, cancellation, or reschedule), never
  from inside the transaction.
  """

  require Logger

  @doc "The PubSub topic carrying seat updates for a meeting type."
  @spec topic(integer()) :: String.t()
  def topic(meeting_type_id), do: "group_seats:#{meeting_type_id}"

  @doc """
  Broadcasts `{:seat_update, meeting_type_id}` for a committed seat change.

  Broadcast failures are logged and swallowed: a missed live update degrades
  to the booker discovering the change at submit time, which the seat
  transaction handles anyway.
  """
  @spec broadcast_seat_change(integer()) :: :ok
  def broadcast_seat_change(meeting_type_id) do
    case Phoenix.PubSub.broadcast(
           Tymeslot.PubSub,
           topic(meeting_type_id),
           {:seat_update, meeting_type_id}
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Seat update broadcast failed",
          reason: inspect(reason),
          meeting_type_id: meeting_type_id
        )

        :ok
    end
  end
end
