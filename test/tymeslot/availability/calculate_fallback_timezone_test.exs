defmodule Tymeslot.Availability.CalculateFallbackTimezoneTest do
  @moduledoc """
  The business-hours fallback the month grid and the week strip draw before a
  conflict-aware availability map exists, for an owner and a booker in
  different timezones.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :availability

  alias Tymeslot.Availability.Calculate

  # A Tokyo owner open Monday to Friday 09:00-17:00 JST (UTC+9), seen from Los
  # Angeles in January (PST, UTC-8, so 17 hours behind): each Tokyo day lands
  # on the booker's previous day, 16:00-24:00. The booker's Sunday to Thursday
  # are open; Friday and Saturday have nothing. The fallback once read the
  # owner's weekday off the booker's date, drawing Sunday closed and Friday
  # open. January is used because Los Angeles is always on PST then, which
  # keeps the expected days fixed whatever the date the suite runs on.
  describe "business-hours fallback across timezones" do
    setup do
      profile = insert(:profile, timezone: "Asia/Tokyo")
      schedule = insert(:availability_schedule, profile: profile, is_default: true)

      for day_of_week <- 1..5 do
        insert(:weekly_availability,
          schedule: schedule,
          day_of_week: day_of_week,
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00],
          is_available: true
        )
      end

      config = %{
        schedule_id: schedule.id,
        owner_timezone: "Asia/Tokyo",
        duration_minutes: 30,
        min_advance_hours: 0,
        max_advance_booking_days: 400
      }

      sunday = january_sunday()
      %{config: config, week: Enum.map(0..6, &Date.add(sunday, &1))}
    end

    test "the week strip fallback draws the booker's days, not the owner's", %{
      config: config,
      week: week
    } do
      drawn =
        Map.new(week, fn date ->
          {Date.day_of_week(date),
           Calculate.day_bookable_by_business_hours?(date, "America/Los_Angeles", config)}
        end)

      assert drawn == %{
               7 => true,
               1 => true,
               2 => true,
               3 => true,
               4 => true,
               5 => false,
               6 => false
             }

      offered =
        Map.new(week, fn date ->
          {:ok, slots} =
            Calculate.available_slots(
              date,
              30,
              "America/Los_Angeles",
              "Asia/Tokyo",
              [],
              config
            )

          {Date.day_of_week(date), slots != []}
        end)

      assert drawn == offered
    end

    test "the month grid fallback draws the booker's days, not the owner's", %{
      config: config,
      week: [sunday | _rest] = week
    } do
      days =
        Calculate.get_calendar_days(
          "America/Los_Angeles",
          sunday.year,
          sunday.month,
          :sunday,
          config
        )

      week_strings = MapSet.new(week, &Date.to_string/1)

      drawn =
        for day <- days, MapSet.member?(week_strings, day.date), into: %{} do
          {day.date |> Date.from_iso8601!() |> Date.day_of_week(), day.available}
        end

      assert drawn == %{
               7 => true,
               1 => true,
               2 => true,
               3 => true,
               4 => true,
               5 => false,
               6 => false
             }
    end
  end

  # The second Sunday of next January: a whole week inside one month and
  # inside PST, so both the week strip and the month grid see all of it.
  defp january_sunday do
    first = Date.new!(Date.utc_today().year + 1, 1, 8)
    Date.add(first, rem(7 - Date.day_of_week(first), 7))
  end
end
