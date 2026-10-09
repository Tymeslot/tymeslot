defmodule Tymeslot.Availability.ReachTest do
  @moduledoc """
  Pins the reaches the booking path pads its reads by.

  The values are derived from the meeting and buffer bounds in
  `Tymeslot.Validation.Constraints`, so a change to either bound, or to the
  derivation, moves every read around a set of dates at once. These are the
  values the engine was built and tested against: the busy fetch pads two
  UTC days, a calendar fetch reaches two days past the last bookable date,
  and the slot engine reads three owner dates either side of a booker's date.
  """

  use ExUnit.Case, async: true

  @moduletag :availability
  @moduletag :unit

  alias Tymeslot.Availability.Reach
  alias Tymeslot.Validation.Constraints

  @minutes_per_day 1440

  test "the longest meeting is a day" do
    assert Reach.max_meeting_minutes() == 1440
  end

  test "the busy fetch pads two UTC days either side" do
    assert Reach.utc_padding_days() == 2
  end

  test "a meeting and its after-buffer reach two days past its start date" do
    assert Reach.meeting_days() == 2
  end

  test "the slot engine reads three owner dates either side" do
    assert Reach.owner_days() == 3
  end

  test "each reach covers the span it stands for" do
    meeting_span = Reach.max_meeting_minutes() + Constraints.buffer_minutes_range().last

    # A day-long meeting plus its longest after-buffer, from its start.
    assert Reach.meeting_days() * @minutes_per_day >= meeting_span
    # UTC+14 from UTC, then that meeting.
    assert Reach.utc_padding_days() * @minutes_per_day >= 14 * 60 + meeting_span
    # The 26-hour zone gap, then a day-long window into the next date.
    assert Reach.owner_days() * @minutes_per_day >= 26 * 60 + @minutes_per_day
  end
end
