defmodule Tymeslot.Availability.CalculateTest do
  @moduledoc """
  Tests for the availability calculation module.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :availability

  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Integrations.Calendar.CalendarEvent

  describe "validate_time_selection/3" do
    test "returns error when date is nil" do
      assert {:error, :date_required} =
               Calculate.validate_time_selection(nil, "10:00 AM", [])
    end

    test "returns error when date is empty string" do
      assert {:error, :date_required} =
               Calculate.validate_time_selection("", "10:00 AM", [])
    end

    test "returns error when time is nil" do
      assert {:error, :time_required} =
               Calculate.validate_time_selection("2025-06-15", nil, [])
    end

    test "returns error when time is empty string" do
      assert {:error, :time_required} =
               Calculate.validate_time_selection("2025-06-15", "", [])
    end

    test "returns ok when both date and time are provided with valid slots" do
      assert :ok = Calculate.validate_time_selection("2025-06-15", "10:00 AM", ["10:00 AM"])
    end

    test "returns ok with empty slots list when date and time are valid" do
      assert :ok = Calculate.validate_time_selection("2025-06-15", "10:00 AM", [])
    end

    test "returns ok with non-list slots when date and time are valid binaries" do
      assert :ok = Calculate.validate_time_selection("2025-06-15", "10:00 AM", :not_a_list)
    end

    test "returns error with non-binary date" do
      assert {:error, :selection_required} =
               Calculate.validate_time_selection(123, "10:00 AM", [])
    end
  end

  describe "get_calendar_days/4" do
    test "returns 42 days for calendar display" do
      days = Calculate.get_calendar_days("America/New_York", 2025, 6, %{})

      assert length(days) == 42
    end

    test "each day has required keys" do
      days = Calculate.get_calendar_days("America/New_York", 2025, 6, %{})

      for day <- days do
        assert Map.has_key?(day, :date)
        assert Map.has_key?(day, :day)
        assert Map.has_key?(day, :available)
        assert Map.has_key?(day, :past)
        assert Map.has_key?(day, :today)
        assert Map.has_key?(day, :current_month)
      end
    end

    test "marks past dates as not available" do
      # Use a month in the past
      days = Calculate.get_calendar_days("America/New_York", 2020, 1, %{})

      # All days in January 2020 should be past and not available
      january_days = Enum.filter(days, & &1.current_month)

      for day <- january_days do
        assert day.past == true
        assert day.available == false
      end
    end

    test "respects max_advance_booking_days config" do
      config = %{max_advance_booking_days: 7}

      # Get days for a future month
      future_date = Date.add(Date.utc_today(), 60)

      days =
        Calculate.get_calendar_days(
          "America/New_York",
          future_date.year,
          future_date.month,
          config
        )

      # All days beyond 7 days should not be available
      available_days = Enum.filter(days, & &1.available)

      # Should have very few or no available days since we're looking at a month 60 days out
      # with only 7 days advance booking allowed
      assert Enum.all?(available_days, fn day ->
               {:ok, day_date} = Date.from_iso8601(day.date)
               Date.diff(day_date, Date.utc_today()) <= 7
             end)
    end

    test "handles UTC timezone" do
      days = Calculate.get_calendar_days("Etc/UTC", 2025, 6, %{})

      # 1 June 2025 is a Sunday, so the six-week grid needs no leading padding
      # and runs 1 June – 12 July.
      assert List.first(days).date == "2025-06-01"
      assert List.last(days).date == "2025-07-12"

      assert Enum.map(days, & &1.date) ==
               Enum.map(0..41, &Date.to_string(Date.add(~D[2025-06-01], &1)))

      # Exactly the 30 days of June belong to the requested month.
      assert days |> Enum.filter(& &1.current_month) |> Enum.map(& &1.day) == Enum.to_list(1..30)
    end

    test "handles different timezones" do
      days_ny = Calculate.get_calendar_days("America/New_York", 2025, 6, %{})
      days_london = Calculate.get_calendar_days("Europe/London", 2025, 6, %{})
      days_tokyo = Calculate.get_calendar_days("Asia/Tokyo", 2025, 6, %{})

      # The displayed window is derived from the requested year/month alone, so
      # every timezone must render the same dates in the same order.
      dates = Enum.map(days_ny, & &1.date)

      assert dates == Enum.map(days_london, & &1.date)
      assert dates == Enum.map(days_tokyo, & &1.date)
      assert List.first(dates) == "2025-06-01"
      assert List.last(dates) == "2025-07-12"

      # June 2025 is behind every one of these timezones, so no cell may be
      # offered as bookable in any of them.
      for days <- [days_ny, days_london, days_tokyo], day <- days do
        assert day.past, "#{day.date} must be marked past"
        refute day.available, "#{day.date} must not be bookable"
        refute day.today, "#{day.date} must not be marked today"
      end
    end

    test "marks today correctly" do
      today = Date.utc_today()
      days = Calculate.get_calendar_days("Etc/UTC", today.year, today.month, %{})

      today_entry =
        Enum.find(days, fn day ->
          day.date == Date.to_string(today)
        end)

      # The 42-cell grid always spans the whole requested month, so the grid for
      # today's month always contains today.
      assert today_entry, "expected today's month grid to contain today"
      assert today_entry.today == true
      assert today_entry.past == false
    end

    test "handles loading state in availability_map" do
      today = Date.utc_today()
      days = Calculate.get_calendar_days("Etc/UTC", today.year, today.month, %{}, :loading)

      # All future days should have loading: true and available: false
      future_days = Enum.filter(days, &(&1.date >= Date.to_string(today)))

      for day <- future_days do
        assert day.loading == true
        assert day.available == false
      end
    end

    test "respects availability_map when provided as map" do
      today = Date.utc_today()
      today_str = Date.to_string(today)
      tomorrow_str = Date.to_string(Date.add(today, 1))

      # Mock availability map: today available, tomorrow unavailable
      availability_map = %{
        today_str => true,
        tomorrow_str => false
      }

      days =
        Calculate.get_calendar_days("Etc/UTC", today.year, today.month, %{}, availability_map)

      today_entry = Enum.find(days, &(&1.date == today_str))
      tomorrow_entry = Enum.find(days, &(&1.date == tomorrow_str))

      assert today_entry.available == true
      assert tomorrow_entry.available == false
      assert today_entry.loading == false
      assert tomorrow_entry.loading == false
    end

    test "uses fallback_availability_fn from config when provided" do
      today = Date.utc_today()
      today_str = Date.to_string(today)
      tomorrow = Date.add(today, 1)
      tomorrow_str = Date.to_string(tomorrow)

      # Callback that only makes tomorrow available
      fallback_fn = fn
        ^tomorrow -> true
        _other -> false
      end

      config = %{fallback_availability_fn: fallback_fn}

      days = Calculate.get_calendar_days("Etc/UTC", today.year, today.month, config)

      today_entry = Enum.find(days, &(&1.date == today_str))
      tomorrow_entry = Enum.find(days, &(&1.date == tomorrow_str))

      assert today_entry.available == false
      assert tomorrow_entry.available == true
    end
  end

  describe "range_availability/6" do
    test "returns availability for the exact date range requested" do
      start_date = ~D[2027-03-28]
      end_date = ~D[2027-04-06]

      assert {:ok, availability_map} =
               Calculate.range_availability(
                 start_date,
                 end_date,
                 "America/New_York",
                 "America/New_York",
                 [],
                 %{}
               )

      assert map_size(availability_map) == 10

      # Contains keys from both March and April
      assert Map.has_key?(availability_map, "2027-03-28")
      assert Map.has_key?(availability_map, "2027-03-31")
      assert Map.has_key?(availability_map, "2027-04-01")
      assert Map.has_key?(availability_map, "2027-04-06")
    end

    test "marks past dates as unavailable" do
      assert {:ok, availability_map} =
               Calculate.range_availability(
                 ~D[2020-06-25],
                 ~D[2020-07-05],
                 "America/New_York",
                 "America/New_York",
                 [],
                 %{}
               )

      assert Enum.all?(availability_map, fn {_date, available} -> available == false end)
    end

    test "respects max_advance_booking_days in config" do
      config = %{max_advance_booking_days: 7}

      # Check a range far in the future
      future_start = Date.add(Date.utc_today(), 60)
      future_end = Date.add(future_start, 10)

      assert {:ok, availability_map} =
               Calculate.range_availability(
                 future_start,
                 future_end,
                 "America/New_York",
                 "America/New_York",
                 [],
                 config
               )

      # All dates should be unavailable since they're beyond 7 days
      assert Enum.all?(availability_map, fn {_date, available} -> available == false end)
    end
  end

  describe "month_availability/6" do
    test "returns availability map for a month" do
      assert {:ok, availability_map} =
               Calculate.month_availability(
                 2025,
                 6,
                 "America/New_York",
                 "America/New_York",
                 [],
                 %{}
               )

      # June has 30 days
      assert map_size(availability_map) == 30
    end

    test "marks all dates in the past as unavailable" do
      assert {:ok, availability_map} =
               Calculate.month_availability(
                 2020,
                 6,
                 "America/New_York",
                 "America/New_York",
                 [],
                 %{}
               )

      # All dates in June 2020 should be false (past)
      assert Enum.all?(availability_map, fn {_date, available} -> available == false end)
    end

    test "handles events parameter" do
      timezone = "America/New_York"

      # A month wholly in the past is unavailable whatever the events say, so
      # the blocked day has to sit inside the booking window to prove anything.
      blocked = next_weekday(Date.add(Date.utc_today(), 10))

      events = [
        CalendarEvent.new!(%{
          uid: "calc-test-event",
          calendar_integration_id: 1,
          provider: :google,
          provider_event_id: "calc-test-event",
          provider_calendar_id: "primary",
          all_day: false,
          start_at: DateTime.new!(blocked, ~T[00:00:00], timezone),
          end_at: DateTime.new!(Date.add(blocked, 1), ~T[00:00:00], timezone),
          synced_at: DateTime.utc_now()
        })
      ]

      assert {:ok, without_events} =
               Calculate.month_availability(
                 blocked.year,
                 blocked.month,
                 timezone,
                 timezone,
                 [],
                 %{}
               )

      assert {:ok, with_events} =
               Calculate.month_availability(
                 blocked.year,
                 blocked.month,
                 timezone,
                 timezone,
                 events,
                 %{}
               )

      key = Date.to_string(blocked)

      assert without_events[key] == true,
             "expected #{key} to be bookable before the event is supplied"

      assert with_events[key] == false,
             "a day-long blocking event must remove #{key} from availability"

      # Nothing but the covered day may change.
      assert Map.delete(with_events, key) == Map.delete(without_events, key)
    end

    test "respects max_advance_booking_days in config" do
      config = %{max_advance_booking_days: 7}

      # Check a month far in the future
      future_year = Date.utc_today().year + 1

      assert {:ok, availability_map} =
               Calculate.month_availability(
                 future_year,
                 6,
                 "America/New_York",
                 "America/New_York",
                 [],
                 config
               )

      # All dates should be unavailable since they're beyond 7 days
      assert Enum.all?(availability_map, fn {_date, available} -> available == false end)
    end
  end

  describe "available_slots/6" do
    test "returns empty list on weekend without profile settings" do
      today = Date.utc_today()

      days_until_saturday =
        case Date.day_of_week(today) do
          6 -> 0
          7 -> 6
          dow -> 6 - dow
        end

      saturday = Date.add(today, days_until_saturday)

      assert {:ok, slots} =
               Calculate.available_slots(
                 saturday,
                 30,
                 "Etc/UTC",
                 "Etc/UTC",
                 [],
                 %{}
               )

      assert slots == []
    end

    test "respects schedule business hours when available" do
      profile = insert(:profile, timezone: "America/New_York")
      schedule = insert(:availability_schedule, profile: profile, is_default: true)

      days_ahead =
        case Date.day_of_week(Date.utc_today()) do
          # if Friday, jump to Monday to avoid weekend
          5 -> 3
          # Saturday to Monday
          6 -> 2
          # Sunday to Monday
          7 -> 1
          _other -> 1
        end

      future_weekday = Date.add(Date.utc_today(), days_ahead)

      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: Date.day_of_week(future_weekday),
        start_time: ~T[09:00:00],
        end_time: ~T[10:00:00],
        is_available: true
      )

      config = %{schedule_id: schedule.id}

      assert {:ok, slots} =
               Calculate.available_slots(
                 future_weekday,
                 30,
                 "America/New_York",
                 "America/New_York",
                 [],
                 config
               )

      assert "9:00 AM" in slots
      assert "9:30 AM" in slots
    end
  end

  describe "available_slots/6 with a slot interval" do
    test "offers denser starts when the interval is shorter than the duration" do
      date = interval_test_date()
      config = interval_test_config(date, duration_minutes: 30, slot_interval_minutes: 5)

      assert {:ok, slots} =
               Calculate.available_slots(date, 30, "Europe/London", "Europe/London", [], config)

      assert "9:05 AM" in slots
      assert "9:10 AM" in slots
    end

    test "offers only rounder starts when the interval is longer than the duration" do
      date = interval_test_date()
      config = interval_test_config(date, duration_minutes: 30, slot_interval_minutes: 60)

      assert {:ok, slots} =
               Calculate.available_slots(date, 30, "Europe/London", "Europe/London", [], config)

      assert slots != []

      assert Enum.all?(slots, &String.contains?(&1, ":00 ")),
             "every start should be on the hour, got: #{inspect(slots)}"
    end

    test "a config without the key behaves exactly as before" do
      date = interval_test_date()
      with_key = interval_test_config(date, duration_minutes: 30, slot_interval_minutes: 30)

      without_key =
        date
        |> interval_test_config(duration_minutes: 30)
        |> Map.delete(:slot_interval_minutes)

      assert {:ok, a} =
               Calculate.available_slots(
                 date,
                 30,
                 "Europe/London",
                 "Europe/London",
                 [],
                 with_key
               )

      assert {:ok, b} =
               Calculate.available_slots(
                 date,
                 30,
                 "Europe/London",
                 "Europe/London",
                 [],
                 without_key
               )

      assert a == b
    end
  end

  describe "get_calendar_days/5 query cost" do
    # This runs inside the template render of the public booking page, so the
    # per-day business-hours fallback must not be a query per day.
    test "reads the weekly schedule and overrides once for the whole grid" do
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

      next_month = Date.add(Date.utc_today(), 31)

      sources =
        capture_query_sources(fn ->
          Calculate.get_calendar_days(
            "Etc/UTC",
            next_month.year,
            next_month.month,
            %{schedule_id: schedule.id, owner_timezone: "Etc/UTC"}
          )
        end)

      # The grid holds 42 days, all but a handful of them future, so an
      # unprefetched run issues dozens of each.
      assert Enum.count(sources, &(&1 == "weekly_availability")) <= 1
      assert Enum.count(sources, &(&1 == "availability_overrides")) <= 1
    end
  end

  defp capture_query_sources(fun) do
    parent = self()
    ref = make_ref()
    handler_id = "calculate-query-spy-#{inspect(ref)}"

    :telemetry.attach(
      handler_id,
      [:tymeslot, :repo, :query],
      # The handler runs in the process that issued the query, so this is what
      # keeps a concurrently running async test's queries out of the count.
      fn _event, _measurements, %{source: source}, _config ->
        if self() == parent, do: send(parent, {:query_source, ref, source})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    fun.()

    drain_query_sources(ref, [])
  end

  defp drain_query_sources(ref, acc) do
    receive do
      {:query_source, ^ref, source} -> drain_query_sources(ref, [source | acc])
    after
      0 -> acc
    end
  end

  # The fallback business hours cover Monday–Friday only, so a date used to
  # prove availability has to land on a weekday.
  defp next_weekday(date) do
    case Date.day_of_week(date) do
      6 -> Date.add(date, 2)
      7 -> Date.add(date, 1)
      _weekday -> date
    end
  end

  # A weekday comfortably inside the default booking window (min_advance_hours
  # and max_advance_booking_days), so the slot-interval tests below aren't
  # tripped up by either constraint or by landing on a weekend.
  defp interval_test_date, do: next_weekday(Date.add(Date.utc_today(), 10))

  # A schedule with a 09:00-11:00 window on `date`'s weekday, wide enough to
  # tell a 5-minute interval, a 60-minute interval, and the duration-locked
  # default apart from one another.
  defp interval_test_config(date, opts) do
    profile = insert(:profile, timezone: "Europe/London")
    schedule = insert(:availability_schedule, profile: profile, is_default: true)

    insert(:weekly_availability,
      schedule: schedule,
      day_of_week: Date.day_of_week(date),
      start_time: ~T[09:00:00],
      end_time: ~T[11:00:00],
      is_available: true
    )

    duration_minutes = Keyword.fetch!(opts, :duration_minutes)
    config = %{schedule_id: schedule.id, duration_minutes: duration_minutes}

    case Keyword.fetch(opts, :slot_interval_minutes) do
      {:ok, value} -> Map.put(config, :slot_interval_minutes, value)
      :error -> config
    end
  end
end
