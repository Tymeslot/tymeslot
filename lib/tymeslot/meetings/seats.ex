defmodule Tymeslot.Meetings.Seats do
  @moduledoc """
  Seat arithmetic for group meetings.

  A meeting's taken seats are its live participants plus their guests, so a
  booking with G guest emails consumes `1 + G` seats. A guest who declines
  gives their seat back (`holds_seat?/1`); answering yes again takes one only
  while one is free (`Tymeslot.Meetings.Guests.record_rsvp/2`). Query work is
  delegated to `Tymeslot.Meetings.ParticipantQueries`; the arithmetic and
  the traffic-light thresholds live here so availability, booking and the
  themes all share one definition.

  What a booking page says about a slot's seats is the organiser's choice,
  made per meeting type (`show_seat_availability`, `last_spots_threshold`)
  and decided once by `display/3`.
  """

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries

  # A slot turns amber at half or fewer seats remaining, and red at 20% or
  # fewer (or on the very last seat).
  @amber_threshold 0.5
  @red_threshold 0.2

  @doc "Seats taken on a meeting: live participants plus their guests who hold a seat."
  @spec seats_taken(binary()) :: non_neg_integer()
  def seats_taken(meeting_id), do: ParticipantQueries.count_seats_taken(meeting_id)

  @doc """
  Seats taken from already-loaded participant and guest lists: the
  participants plus the guests who hold a seat.

  For callers that already hold a meeting's preloaded associations (the
  dashboard meeting cards) and would otherwise re-derive this count
  themselves — which risks drifting from `seats_taken/1`, the query-backed
  definition, as either one's counting rule changes.
  """
  @spec seats_taken(list(), list()) :: non_neg_integer()
  def seats_taken(participants, guests) when is_list(participants) and is_list(guests),
    do: length(participants) + Enum.count(guests, &holds_seat?/1)

  @doc "Whether a guest holds a seat: every guest does, until they decline."
  @spec holds_seat?(map()) :: boolean()
  def holds_seat?(%{status: "declined"}), do: false
  def holds_seat?(_guest), do: true

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
  @spec seat_level(pos_integer(), pos_integer()) :: level()
  def seat_level(seats_left, capacity)
      when seats_left == 1 or seats_left / capacity <= @red_threshold,
      do: :red

  def seat_level(seats_left, capacity) when seats_left / capacity <= @amber_threshold,
    do: :amber

  def seat_level(_seats_left, _capacity), do: :green

  @typedoc """
  What a booking page shows on a group slot: the traffic-light `level` when
  the organiser shows availability, and the exact `spots_left` once the
  slot is down to the organiser's last-spots threshold. `nil` shows nothing.
  """
  @type display :: %{level: level() | nil, spots_left: pos_integer() | nil} | nil
  @type level :: :green | :amber | :red

  @doc """
  What a booking page shows on a slot with `seats_left` of `capacity` free,
  under the meeting type's display settings.
  """
  @spec display(pos_integer(), pos_integer(), map()) :: display()
  def display(seats_left, capacity, settings) do
    level =
      if Map.get(settings, :show_seat_availability, true),
        do: seat_level(seats_left, capacity)

    spots_left =
      if last_spots?(seats_left, Map.get(settings, :last_spots_threshold)), do: seats_left

    if level || spots_left, do: %{level: level, spots_left: spots_left}
  end

  defp last_spots?(seats_left, threshold) when is_integer(threshold), do: seats_left <= threshold
  defp last_spots?(_seats_left, _threshold), do: false
end
