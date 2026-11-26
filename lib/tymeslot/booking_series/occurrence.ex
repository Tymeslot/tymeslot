defmodule Tymeslot.BookingSeries.Occurrence do
  @moduledoc """
  One session of a series as `Tymeslot.BookingSeries.Check` judged it.

  `position` is 1-based. `status` is `:available` or `{:unavailable, reason}`,
  the first rule the occurrence broke:

    * `:in_past`, `:too_soon`: not far enough in the future;
    * `:too_far_ahead`: beyond the booking window (first occurrence only);
    * `:beyond_series_span`: more than a year after the first occurrence;
    * `:outside_schedule`: the host's schedule does not offer the time;
    * `:no_session`: a fixed-date type has no open session or offered time
      at that start;
    * `:calendar_busy`: the host's connected calendar is busy;
    * `:booked`: another Tymeslot booking is in the way;
    * `:overlaps_session`: an earlier session of the same series is in the
      way, buffers included;
    * `:already_booked`: the booker already holds a seat in that session;
    * `:seat_held`: the booker's checkout for a seat in that session is
      still open;
    * `:session_full`: the group session has too few seats left;
    * `:limit_reached`: a booking limit would be exceeded, counting the
      series' own earlier occurrences.

  `seats_left` is the seats a group session has before this booking (its
  capacity when the occurrence would start a new one); nil for a one-to-one
  type and for an occurrence with no session to book (`:no_session`).
  """

  @type reason ::
          :in_past
          | :too_soon
          | :too_far_ahead
          | :beyond_series_span
          | :outside_schedule
          | :no_session
          | :calendar_busy
          | :booked
          | :overlaps_session
          | :already_booked
          | :seat_held
          | :session_full
          | :limit_reached

  @type status :: :available | {:unavailable, reason()}

  @type t :: %__MODULE__{
          position: pos_integer(),
          start: DateTime.t(),
          end: DateTime.t(),
          status: status(),
          seats_left: non_neg_integer() | nil
        }

  @enforce_keys [:position, :start, :end]
  defstruct [:position, :start, :end, status: :available, seats_left: nil]

  @doc "Whether the occurrence passed every check."
  @spec available?(t()) :: boolean()
  def available?(%__MODULE__{status: :available}), do: true
  def available?(%__MODULE__{status: {:unavailable, _reason}}), do: false
end
