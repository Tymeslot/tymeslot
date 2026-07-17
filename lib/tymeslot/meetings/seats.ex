defmodule Tymeslot.Meetings.Seats do
  @moduledoc """
  Seat arithmetic for group meetings.

  A meeting's taken seats are its live participants plus their guests, so a
  booking with G guest emails consumes `1 + G` seats. Query work is
  delegated to `Tymeslot.Meetings.ParticipantQueries`; the arithmetic and
  the traffic-light thresholds live here so availability, booking and the
  themes all share one definition.
  """

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries

  # A slot turns amber at half or fewer seats remaining, and red at 20% or
  # fewer (or on the very last seat).
  @amber_threshold 0.5
  @red_threshold 0.2

  @doc "Seats taken on a meeting: live participants plus their guests."
  @spec seats_taken(binary()) :: non_neg_integer()
  def seats_taken(meeting_id), do: ParticipantQueries.count_seats_taken(meeting_id)

  @doc """
  Seats still free on a meeting, never negative. The organiser may lower
  `max_participants` below the seats already booked; existing bookings
  stand and the slot simply reads as full.
  """
  @spec seats_left(MeetingSchema.t(), pos_integer()) :: non_neg_integer()
  def seats_left(%MeetingSchema{id: meeting_id}, max_participants)
      when is_integer(max_participants) do
    max(max_participants - seats_taken(meeting_id), 0)
  end

  @doc """
  Map of meeting `start_time` to seats taken for confirmed meetings of the
  given meeting type whose start falls in `[from_utc, to_utc)`. Slots with
  no participants are absent from the map.
  """
  @spec seat_counts_for_range(integer(), DateTime.t(), DateTime.t()) ::
          %{DateTime.t() => non_neg_integer()}
  def seat_counts_for_range(meeting_type_id, from_utc, to_utc) do
    ParticipantQueries.seat_counts_for_range(meeting_type_id, from_utc, to_utc)
  end

  @doc """
  Traffic-light level for a slot with `seats_left` of `capacity` remaining.

    * `:red` — last seat, or 20% or fewer seats remaining
    * `:amber` — half or fewer seats remaining
    * `:green` — more than half the seats free

  Callers never pass `seats_left <= 0`: full slots are hidden before the
  traffic light is consulted.
  """
  @spec seat_level(pos_integer(), pos_integer()) :: :green | :amber | :red
  def seat_level(seats_left, capacity)
      when seats_left == 1 or seats_left / capacity <= @red_threshold,
      do: :red

  def seat_level(seats_left, capacity) when seats_left / capacity <= @amber_threshold,
    do: :amber

  def seat_level(_seats_left, _capacity), do: :green
end
