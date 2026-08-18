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
end
