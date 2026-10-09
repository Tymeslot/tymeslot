defmodule Tymeslot.Availability.Reach do
  @moduledoc """
  How far past the dates it renders the booking path has to look.

  A slot listed under one date can begin up to a timezone gap away from it,
  run for up to a day, and keep its after-buffer clear beyond that. Every
  module that reads data around a set of dates (the schedule, the host's
  bookings, their calendars) pads its range by one of the reaches here, so
  the reaches all follow from the same few bounds and cannot drift apart:

    * the longest meeting, `Constraints.duration_minutes_range/0`;
    * the longest buffer, `Constraints.buffer_minutes_range/0`;
    * the widest timezone offsets in use, UTC-12 to UTC+14.
  """

  alias Tymeslot.Validation.Constraints

  @minutes_per_day 1440
  @max_meeting_minutes Constraints.duration_minutes_range().last
  @max_buffer_minutes Constraints.buffer_minutes_range().last

  # Pacific/Kiritimati is UTC+14 and the furthest west a zone sits is UTC-12,
  # so two zones are at most 26 hours apart and no zone is more than 14 hours
  # from UTC.
  @max_utc_offset_minutes 14 * 60
  @max_zone_gap_minutes 26 * 60

  # A meeting and the buffer after it, from the minute it starts.
  @meeting_span_minutes @max_meeting_minutes + @max_buffer_minutes

  @meeting_days ceil(@meeting_span_minutes / @minutes_per_day)
  @utc_padding_days ceil((@max_utc_offset_minutes + @meeting_span_minutes) / @minutes_per_day)
  # The zone gap moves a booker's date to an owner date up to that many days
  # away; one day more reaches the window or meeting that crosses into the
  # next owner date (both are at most a day long).
  @owner_days ceil(@max_zone_gap_minutes / @minutes_per_day) + 1

  @doc "The longest meeting the engine plans for, in minutes: a day."
  @spec max_meeting_minutes() :: pos_integer()
  def max_meeting_minutes, do: @max_meeting_minutes

  @doc """
  How many days past the date a meeting starts on (in UTC) its end and
  after-buffer can reach. A calendar fetch covering the last bookable date
  reaches this much further.
  """
  @spec meeting_days() :: pos_integer()
  def meeting_days, do: @meeting_days

  @doc """
  How many UTC days either side of a run of booker dates something can still
  touch a slot listed under them: the booker's offset from UTC, plus a
  meeting and its buffer.
  """
  @spec utc_padding_days() :: pos_integer()
  def utc_padding_days, do: @utc_padding_days

  @doc """
  How many owner dates either side of a booker's date the slot engine reads
  the schedule, time off and events for: the gap between the two zones, plus
  the overnight window or day-long meeting crossing into the next date.
  """
  @spec owner_days() :: pos_integer()
  def owner_days, do: @owner_days
end
