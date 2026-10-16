defmodule TymeslotWeb.Live.Scheduling.CalendarHelpersTest do
  use Tymeslot.DataCase, async: true

  @moduletag :scheduling

  import Tymeslot.Test.ClockHelpers

  alias Phoenix.LiveView.Socket
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
        Calculate.get_calendar_days(
          "Etc/UTC",
          today.year,
          today.month,
          :sunday,
          month_config(schedule)
        )

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
        buffer_before_minutes: schedule.buffer_before_minutes,
        buffer_after_minutes: schedule.buffer_after_minutes,
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

  describe "display_range/3" do
    test "returns range covering 42-day calendar grid" do
      {start_date, end_date} = Calculate.display_range(2027, 6, :sunday)
      assert Date.diff(end_date, start_date) + 1 == 42
    end

    test "start date is a Sunday" do
      {start_date, _end_date} = Calculate.display_range(2027, 6, :sunday)
      # Date.day_of_week returns 7 for Sunday
      assert Date.day_of_week(start_date) == 7
    end

    test "matches Calculate.get_calendar_days range exactly" do
      {start_date, end_date} = Calculate.display_range(2027, 3, :sunday)
      calendar_days = Calculate.get_calendar_days("Etc/UTC", 2027, 3, :sunday, %{})
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
      days = CalendarHelpers.get_calendar_days("Etc/UTC", 2025, 6, :sunday, profile, nil)

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
    test "the fetched block covers the week of a month's last day on either week start" do
      # August 2026 is the shape that once escaped: a 31-day month whose 1st
      # is a Saturday, fetched Sunday-anchored while the strip was
      # Monday-anchored. Both now follow `:week_start`, so the week of the
      # 31st ends inside the block whichever day the weeks start on.
      for week_start <- [:monday, :sunday] do
        {_start_date, end_date} = Calculate.display_range(2026, 8, week_start)
        strip_start = Date.beginning_of_week(~D[2026-08-31], week_start)

        assert Date.compare(Date.add(strip_start, 6), end_date) != :gt,
               "the #{week_start} week of 31 August runs past the fetched block"
      end
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
          buffer_before_minutes: 0,
          buffer_after_minutes: 0
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

  describe "handle_month_navigation/2" do
    defp month_socket(year, month) do
      %Socket{
        assigns: %{
          __changed__: %{},
          current_year: year,
          current_month: month,
          selected_date: "#{year}-#{String.pad_leading("#{month}", 2, "0")}-03",
          selected_time: "10:00",
          available_slots: ["10:00"],
          month_availability_map: %{},
          availability_status: :loaded
        }
      }
    end

    test "steps forward into the next year" do
      socket = CalendarHelpers.handle_month_navigation(month_socket(2027, 12), :next)
      assert {socket.assigns.current_year, socket.assigns.current_month} == {2028, 1}
    end

    test "steps back into the previous year" do
      socket = CalendarHelpers.handle_month_navigation(month_socket(2027, 1), :prev)
      assert {socket.assigns.current_year, socket.assigns.current_month} == {2026, 12}
    end

    test "drops the day and time picked in the month being left, and its availability" do
      socket = CalendarHelpers.handle_month_navigation(month_socket(2027, 6), :next)

      assert %{
               selected_date: nil,
               selected_time: nil,
               available_slots: [],
               month_availability_map: nil,
               availability_status: :not_loaded
             } = socket.assigns
    end
  end

  describe "anchor_on_today/1" do
    test "opens on the visitor's date when it is already tomorrow there" do
      freeze_clock(~U[2027-01-31 12:00:00Z])

      socket =
        CalendarHelpers.anchor_on_today(calendar_socket(%{user_timezone: "Pacific/Kiritimati"}))

      assert %{
               calendar_today: ~D[2027-02-01],
               current_year: 2027,
               current_month: 2,
               current_week_start: ~D[2027-02-01]
             } = socket.assigns
    end

    test "opens on the week that starts on the visitor's week start" do
      freeze_clock(~U[2027-02-03 12:00:00Z])

      socket =
        CalendarHelpers.anchor_on_today(
          calendar_socket(%{user_timezone: "Etc/UTC", week_start: :sunday})
        )

      assert socket.assigns.current_week_start == ~D[2027-01-31]
      assert socket.assigns.calendar_landing.current_week_start == ~D[2027-01-31]
      assert CalendarHelpers.untouched?(socket.assigns)
    end

    test "opens on the visitor's date when it is still yesterday there" do
      freeze_clock(~U[2027-02-01 05:00:00Z])

      socket =
        CalendarHelpers.anchor_on_today(calendar_socket(%{user_timezone: "Pacific/Pago_Pago"}))

      assert %{
               calendar_today: ~D[2027-01-31],
               current_year: 2027,
               current_month: 1,
               current_week_start: ~D[2027-01-25]
             } = socket.assigns
    end
  end

  describe "untouched?/1" do
    setup do
      freeze_clock(~U[2027-01-31 12:00:00Z])
      :ok
    end

    test "holds for a calendar still on the day it opened on, with no day chosen" do
      assert CalendarHelpers.untouched?(opened_in_tallinn(%{}).assigns)
    end

    test "fails once the booker has moved the month" do
      refute CalendarHelpers.untouched?(opened_in_tallinn(%{current_month: 3}).assigns)
    end

    test "fails once the booker has moved the week" do
      refute CalendarHelpers.untouched?(
               opened_in_tallinn(%{current_week_start: ~D[2027-02-01]}).assigns
             )
    end

    test "fails once the booker has chosen a day" do
      refute CalendarHelpers.untouched?(opened_in_tallinn(%{selected_date: "2027-02-03"}).assigns)
    end

    test "treats a blank selection as none" do
      assert CalendarHelpers.untouched?(opened_in_tallinn(%{selected_date: ""}).assigns)
    end

    test "fails for a calendar the page never placed" do
      refute CalendarHelpers.untouched?(calendar_socket(%{}).assigns)
    end
  end

  describe "selection_out_of_window?/1" do
    # Sunday 31 January in Tallinn, already Monday 1 February in Kiritimati.
    setup do
      freeze_clock(~U[2027-01-31 12:00:00Z])
      :ok
    end

    test "holds for a day already past in the booker's timezone" do
      assert CalendarHelpers.selection_out_of_window?(
               window_socket(%{user_timezone: "Pacific/Kiritimati", selected_date: "2027-01-31"}).assigns
             )
    end

    test "fails for the same day where it is still today" do
      refute CalendarHelpers.selection_out_of_window?(
               window_socket(%{selected_date: "2027-01-31"}).assigns
             )
    end

    test "holds for a day past the booking window" do
      assert CalendarHelpers.selection_out_of_window?(
               window_socket(%{selected_date: "2027-05-02"}).assigns
             )
    end

    test "fails with no day selected" do
      refute CalendarHelpers.selection_out_of_window?(window_socket(%{}).assigns)
    end
  end

  describe "land_on/2" do
    setup do
      freeze_clock(~U[2027-01-31 12:00:00Z])
      :ok
    end

    # The page's own pick: `NextAvailable` selects the day, then lands on it.
    defp landed_on(date) do
      socket = opened_in_tallinn(%{selected_date: Date.to_iso8601(date)})
      CalendarHelpers.land_on(socket, date)
    end

    test "moves the month and week onto the day and leaves the calendar untouched" do
      socket = landed_on(~D[2027-03-10])

      assert %{current_year: 2027, current_month: 3, current_week_start: ~D[2027-03-08]} =
               socket.assigns

      assert CalendarHelpers.untouched?(socket.assigns)
    end

    test "a day the booker clicks afterwards is theirs" do
      socket = landed_on(~D[2027-03-10])

      refute CalendarHelpers.untouched?(Map.put(socket.assigns, :selected_date, "2027-03-11"))
    end

    test "a week the booker moves to afterwards is theirs" do
      socket = landed_on(~D[2027-03-10])

      refute CalendarHelpers.untouched?(
               Map.put(socket.assigns, :current_week_start, ~D[2027-03-15])
             )
    end

    test "a day linked with ?date= is not the page's, however it is opened" do
      # `anchor_on_selection/1` opens a linked day with `anchor_on/2`, which
      # moves the calendar without claiming the position.
      socket =
        CalendarHelpers.anchor_on_selection(
          window_socket(%{selected_date: "2027-01-31", selected_time: nil})
        )

      assert socket.assigns.selected_date == "2027-01-31"
      refute CalendarHelpers.untouched?(socket.assigns)
    end
  end

  describe "anchor_on/2" do
    test "moves the month and the Monday-started week onto the date" do
      socket = CalendarHelpers.anchor_on(calendar_socket(%{}), ~D[2027-03-10])

      assert %{current_year: 2027, current_month: 3, current_week_start: ~D[2027-03-08]} =
               socket.assigns
    end
  end

  describe "anchor_on_selection/1" do
    setup do
      freeze_clock(~U[2027-01-31 12:00:00Z])
      :ok
    end

    test "opens on a chosen day in a later month, week included" do
      socket =
        CalendarHelpers.anchor_on_selection(
          window_socket(%{selected_date: "2027-03-10", selected_time: "10:00 AM"})
        )

      assert %{
               calendar_today: ~D[2027-01-31],
               current_year: 2027,
               current_month: 3,
               current_week_start: ~D[2027-03-08],
               selected_date: "2027-03-10",
               selected_time: "10:00 AM"
             } = socket.assigns
    end

    test "keeps the last day of the booking window" do
      socket = CalendarHelpers.anchor_on_selection(window_socket(%{selected_date: "2027-05-01"}))

      assert %{current_month: 5, current_week_start: ~D[2027-04-26], selected_date: "2027-05-01"} =
               socket.assigns
    end

    test "drops a day before today and opens on today" do
      socket =
        CalendarHelpers.anchor_on_selection(
          window_socket(%{selected_date: "2027-01-30", selected_time: "10:00 AM"})
        )

      assert %{
               current_month: 1,
               current_week_start: ~D[2027-01-25],
               selected_date: nil,
               selected_time: nil
             } = socket.assigns
    end

    test "drops a day past the booking window and opens on today" do
      socket = CalendarHelpers.anchor_on_selection(window_socket(%{selected_date: "2027-05-02"}))

      assert %{current_month: 1, current_week_start: ~D[2027-01-25], selected_date: nil} =
               socket.assigns
    end

    test "judges the day in the visitor's timezone" do
      # Still Sunday 31 January in UTC, but already 1 February in Kiritimati.
      socket =
        CalendarHelpers.anchor_on_selection(
          window_socket(%{user_timezone: "Pacific/Kiritimati", selected_date: "2027-01-31"})
        )

      assert %{calendar_today: ~D[2027-02-01], current_month: 2, selected_date: nil} =
               socket.assigns
    end

    test "with no day chosen, opens on today like anchor_on_today/1" do
      socket = CalendarHelpers.anchor_on_selection(window_socket(%{}))

      assert %{
               calendar_today: ~D[2027-01-31],
               current_month: 1,
               current_week_start: ~D[2027-01-25],
               selected_date: nil
             } = socket.assigns
    end
  end

  # A socket with no organiser, so a month availability fetch stands down.
  defp calendar_socket(assigns) do
    %Socket{
      assigns: Map.merge(%{__changed__: %{}, selected_date: nil, week_start: :monday}, assigns)
    }
  end

  # A calendar in Tallinn whose meeting type allows booking 90 days ahead.
  defp window_socket(assigns) do
    calendar_socket(
      Map.merge(
        %{user_timezone: "Europe/Tallinn", booking_window_days: 90, selected_time: nil},
        assigns
      )
    )
  end

  # A calendar the page opened in Tallinn. `changes` stands for what the
  # booker did afterwards.
  defp opened_in_tallinn(changes) do
    socket = CalendarHelpers.anchor_on_today(calendar_socket(%{user_timezone: "Europe/Tallinn"}))
    %{socket | assigns: Map.merge(socket.assigns, changes)}
  end
end
