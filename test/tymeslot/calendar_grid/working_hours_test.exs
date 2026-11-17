defmodule Tymeslot.CalendarGrid.WorkingHoursTest do
  @moduledoc """
  The hours the grid leaves unshaded: the organiser's default
  availability schedule, read as minutes per ISO weekday.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :availability

  alias Tymeslot.CalendarGrid.WorkingHours

  test "reads the default schedule's weekly hours as minutes" do
    profile = insert(:profile)
    schedule = insert(:availability_schedule, profile: profile, is_default: true)

    insert(:weekly_availability,
      schedule: schedule,
      day_of_week: 1,
      is_available: true,
      start_time: ~T[09:00:00],
      end_time: ~T[17:30:00]
    )

    insert(:weekly_availability, schedule: schedule, day_of_week: 2, is_available: false)

    insert(:weekly_availability,
      schedule: schedule,
      day_of_week: 3,
      is_available: true,
      start_time: ~T[22:00:00],
      end_time: ~T[02:00:00],
      ends_next_day: true
    )

    hours = WorkingHours.for_profile(profile)

    assert hours[1] == [540, 1050]
    assert hours[2] == nil
    assert hours[3] == [1320, 1440]
    assert hours[7] == nil
  end

  test "a non-default schedule is not read" do
    profile = insert(:profile)
    schedule = insert(:availability_schedule, profile: profile, is_default: false)

    insert(:weekly_availability,
      schedule: schedule,
      day_of_week: 1,
      is_available: true,
      start_time: ~T[06:00:00],
      end_time: ~T[07:00:00]
    )

    assert WorkingHours.for_profile(profile) == WorkingHours.fallback()
  end

  test "a profile without a schedule gets weekdays from 08:00 to 18:00" do
    hours = WorkingHours.for_profile(insert(:profile))

    assert hours[1] == [480, 1080]
    assert hours[5] == [480, 1080]
    assert hours[6] == nil
    assert hours[7] == nil
  end

  test "no profile gets the same fallback" do
    assert WorkingHours.for_profile(nil) == WorkingHours.fallback()
  end
end
