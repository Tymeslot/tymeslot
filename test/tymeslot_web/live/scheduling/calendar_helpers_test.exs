defmodule TymeslotWeb.Live.Scheduling.CalendarHelpersTest do
  use Tymeslot.DataCase, async: true

  @moduletag :scheduling

  alias Tymeslot.Availability.Calculate
  alias TymeslotWeb.Live.Scheduling.CalendarHelpers

  describe "get_week_days/4" do
    test "accepts user_timezone parameter and uses it for today detection" do
      week_start = ~D[2027-06-07]
      profile = insert(:profile)
      insert(:availability_schedule, profile: profile, is_default: true, advance_booking_days: 90)
      days = CalendarHelpers.get_week_days(week_start, profile, nil, "America/New_York")
      assert length(days) == 7
      assert Enum.all?(days, &Map.has_key?(&1, :today))
    end

    test "uses availability_map for dates spanning month boundaries" do
      week_start = ~D[2027-03-29]
      profile = insert(:profile)
      insert(:availability_schedule, profile: profile, is_default: true, advance_booking_days: 90)

      availability_map = %{
        "2027-03-29" => true,
        "2027-03-30" => true,
        "2027-03-31" => false,
        "2027-04-01" => true,
        "2027-04-02" => true,
        "2027-04-03" => false,
        "2027-04-04" => true
      }

      days = CalendarHelpers.get_week_days(week_start, profile, availability_map, "Etc/UTC")
      assert Enum.at(days, 0).available == true
      assert Enum.at(days, 2).available == false
      assert Enum.at(days, 3).available == true
    end

    # Both themes call this from inside the schedule template, so the seven-day
    # business-hours fallback must not cost a query per day.
    test "reads the weekly schedule and overrides once for the whole week" do
      profile = insert(:profile, timezone: "Etc/UTC")
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

      parent = self()
      ref = make_ref()
      handler_id = "week-days-query-spy-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:tymeslot, :repo, :query],
        # The handler runs in the process that issued the query, so this is
        # what keeps a concurrently running async test's queries out.
        fn _event, _measurements, %{source: source}, _config ->
          if self() == parent, do: send(parent, {:query_source, ref, source})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # No availability map, so every day takes the business-hours fallback.
      assert length(CalendarHelpers.get_week_days(~D[2027-06-07], profile, nil, "Etc/UTC")) == 7

      sources = drain_query_sources(ref, [])

      assert Enum.count(sources, &(&1 == "weekly_availability")) <= 1
      assert Enum.count(sources, &(&1 == "availability_overrides")) <= 1
    end
  end

  # The week strip used to answer this with its own copy of the rule, which
  # treated today as unconditionally bookable. In Rhythm, which has no month
  # grid, that divergent copy was the only rule a visitor ever saw.
  describe "get_week_days/5 agrees with the month grid about today" do
    test "today is not offered when it cannot clear the minimum notice" do
      profile = insert(:profile, timezone: "Etc/UTC")

      schedule =
        insert(:availability_schedule,
          profile: profile,
          is_default: true,
          min_advance_hours: 240
        )

      for day_of_week <- 1..7 do
        insert(:weekly_availability,
          schedule: schedule,
          day_of_week: day_of_week,
          start_time: ~T[00:00:00],
          end_time: ~T[23:59:00],
          is_available: true
        )
      end

      today = Date.utc_today()
      week_start = Date.add(today, -Date.day_of_week(today, :sunday) + 1)

      week = CalendarHelpers.get_week_days(week_start, profile, nil, "Etc/UTC")

      grid =
        Calculate.get_calendar_days("Etc/UTC", today.year, today.month, month_config(schedule))

      today_string = Date.to_string(today)
      week_today = Enum.find(week, &(&1.date == today_string))
      grid_today = Enum.find(grid, &(&1.date == today_string))

      assert week_today, "expected the week strip to contain today"
      assert grid_today, "expected the month grid to contain today"
      refute grid_today.available
      assert week_today.available == grid_today.available
    end

    defp month_config(schedule) do
      %{
        schedule_id: schedule.id,
        max_advance_booking_days: schedule.advance_booking_days,
        min_advance_hours: schedule.min_advance_hours,
        buffer_minutes: schedule.buffer_minutes,
        owner_timezone: "Etc/UTC"
      }
    end
  end

  defp drain_query_sources(ref, acc) do
    receive do
      {:query_source, ^ref, source} -> drain_query_sources(ref, [source | acc])
    after
      0 -> acc
    end
  end

  describe "display_range/2" do
    test "returns range covering 42-day calendar grid" do
      {start_date, end_date} = CalendarHelpers.display_range(2027, 6)
      assert Date.diff(end_date, start_date) + 1 == 42
    end

    test "start date is a Sunday" do
      {start_date, _end_date} = CalendarHelpers.display_range(2027, 6)
      # Date.day_of_week returns 7 for Sunday
      assert Date.day_of_week(start_date) == 7
    end

    test "matches Calculate.get_calendar_days range exactly" do
      {start_date, end_date} = CalendarHelpers.display_range(2027, 3)
      calendar_days = Calculate.get_calendar_days("Etc/UTC", 2027, 3, %{})
      assert Date.to_string(start_date) == List.first(calendar_days).date
      assert Date.to_string(end_date) == List.last(calendar_days).date
    end
  end

  describe "trim_trailing_other_month_weeks/1" do
    defp week(current_month?), do: for(_i <- 1..7, do: %{current_month: current_month?})

    test "drops trailing weeks that are entirely other-month" do
      days = week(true) ++ week(true) ++ week(false)
      result = CalendarHelpers.trim_trailing_other_month_weeks(days)

      assert length(result) == 14
      assert Enum.all?(result, & &1.current_month)
    end

    test "keeps a trailing week that contains any current-month day" do
      mixed_week = for i <- 1..7, do: %{current_month: i <= 3}
      days = week(true) ++ mixed_week
      result = CalendarHelpers.trim_trailing_other_month_weeks(days)

      assert length(result) == 14
    end

    test "never trims leading or current-month weeks" do
      days = week(true) ++ week(true)
      assert CalendarHelpers.trim_trailing_other_month_weeks(days) == days
    end

    test "returns [] for an empty grid" do
      assert CalendarHelpers.trim_trailing_other_month_weeks([]) == []
    end

    test "treats a missing :current_month key as other-month" do
      days = week(true) ++ for(_i <- 1..7, do: %{})
      assert length(CalendarHelpers.trim_trailing_other_month_weeks(days)) == 7
    end
  end

  describe "get_calendar_days/5 trims trailing other-month weeks" do
    test "keeps full weeks, all current-month days, and no all-next-month tail" do
      profile = insert(:profile)
      insert(:availability_schedule, profile: profile, is_default: true, advance_booking_days: 90)
      days = CalendarHelpers.get_calendar_days("Etc/UTC", 2025, 6, profile, nil)

      # Whole weeks only, and the last rendered week still has a real June day.
      assert rem(length(days), 7) == 0
      assert Enum.any?(Enum.take(days, -7), & &1.current_month)

      # The current month is never truncated.
      current = Enum.filter(days, & &1.current_month)
      assert length(current) == Date.days_in_month(~D[2025-06-01])
    end
  end

  # Rhythm's week view and Quill's narrow-screen weekly row both render from
  # `get_week_days/5` and both disable the day button on `available: false`,
  # so the distinction between "the calendar says no" and "nobody asked the
  # calendar" is made once, here, for both themes.
  describe "get_week_days/5 with a week the availability map does not cover" do
    test "the fetched block genuinely fails to cover the week of a month's last day" do
      # August 2026 is the shape: a 31-day month whose 1st is a Saturday. The
      # fetch is Sunday-anchored and the strip is Monday-anchored, so the week
      # of the 31st runs one day past the block. Next occurrence 2027-05.
      {_start_date, end_date} = CalendarHelpers.display_range(2026, 8)
      week_start = Date.beginning_of_week(~D[2026-08-31], :monday)

      assert end_date == ~D[2026-09-05]
      assert week_start == ~D[2026-08-31]

      assert Date.compare(Date.add(week_start, 6), end_date) == :gt,
             "the week strip no longer escapes the fetched block; this fixture is stale"
    end

    test "a day past the end of the block is offered, not greyed out" do
      profile = bookable_profile()
      week_start = future_monday()

      # Everything but the trailing Sunday, which is what a block ending on a
      # Saturday leaves uncovered.
      map = availability_for(week_start, 0..5, true)

      days = CalendarHelpers.get_week_days(week_start, profile, map, "Etc/UTC")
      uncovered = Enum.at(days, 6)

      assert uncovered.date == Date.to_string(Date.add(week_start, 6))

      assert uncovered.available,
             "a day the fetch never covered was rendered as fully booked"

      # Not a spinner either: nothing is going to fetch it, so a loading state
      # would never resolve.
      refute uncovered.loading
    end

    test "the six days before the start of the block are offered, not greyed out" do
      # The mirror case, reachable through `NextAvailable.align_to/2`: landing
      # on the block's first day (a Sunday) moves the strip to the Monday six
      # days earlier, entirely outside the block.
      profile = bookable_profile()
      week_start = future_monday()
      map = availability_for(week_start, 6..6, true)

      days = CalendarHelpers.get_week_days(week_start, profile, map, "Etc/UTC")
      uncovered = Enum.take(days, 6)

      assert Enum.all?(uncovered, & &1.available),
             "days before the fetched block were rendered as fully booked"
    end

    test "a gap in the week does not override the days the map does answer for" do
      # The fallback is business hours, which would say yes to every day here.
      # It must only ever answer for days the map is silent about, or a real
      # conflict would be painted as bookable and the booker sent to a slot
      # list that turns out to be empty.
      profile = bookable_profile()
      week_start = future_monday()

      map =
        week_start
        |> availability_for(0..5, true)
        |> Map.put(Date.to_string(Date.add(week_start, 2)), false)

      days = CalendarHelpers.get_week_days(week_start, profile, map, "Etc/UTC")

      refute Enum.at(days, 2).available
      assert Enum.at(days, 6).available
    end

    defp bookable_profile do
      profile = insert(:profile, timezone: "Etc/UTC")

      schedule =
        insert(:availability_schedule,
          profile: profile,
          is_default: true,
          advance_booking_days: 90,
          min_advance_hours: 0,
          buffer_minutes: 0
        )

      for day_of_week <- 1..7 do
        insert(:weekly_availability,
          schedule: schedule,
          day_of_week: day_of_week,
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00],
          is_available: true
        )
      end

      profile
    end

    # Far enough ahead that every day of the week is future and inside the
    # booking window, so the business-hours fallback's answer is governed by
    # the schedule rather than by which day the suite happens to run on.
    defp future_monday do
      Date.utc_today() |> Date.add(14) |> Date.beginning_of_week(:monday)
    end

    defp availability_for(week_start, offsets, value) do
      Map.new(offsets, fn offset ->
        {week_start |> Date.add(offset) |> Date.to_string(), value}
      end)
    end
  end
end
