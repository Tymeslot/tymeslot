defmodule Tymeslot.Availability.SlotGridPropertyTest do
  @moduledoc """
  The listing and fit rules of `SlotGrid`, checked against an independent
  minute-by-minute model of available time (weekly windows and their breaks;
  overrides and time off are covered by the examples in `SlotGridTest`): what
  is listed is valid, and every grid start that passes the rules is listed.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :availability

  import Tymeslot.Test.SlotGridHelpers

  alias Tymeslot.Availability.{SlotGrid, TimeSlots}
  alias Tymeslot.Test.ScheduleGenerators, as: Gen
  alias Tymeslot.Utils.DateTimeUtils

  @checked :slot_grid_property_checked

  property "every listed start begins on the date, round-trips through its label, and fits" do
    Process.put(@checked, 0)

    check all(
            date <- Gen.date(),
            owner_tz <- Gen.zone(),
            user_tz <- Gen.zone(),
            duration <- member_of([30, 60, 90, 240, 1440]),
            interval <- Gen.interval(),
            days <- Gen.week(Gen.any_window()),
            max_runs: 300
          ) do
      config = pure_config(days: days, interval: interval)
      {:ok, starts} = SlotGrid.starts_for_date(date, duration, owner_tz, user_tz, config)
      open = open_minutes(days, owner_tz, Date.range(Date.add(date, -3), Date.add(date, 3)))

      assert starts == Enum.sort(starts, DateTime)
      assert starts == Enum.uniq_by(starts, &TimeSlots.format_datetime_slot/1)

      bad =
        Enum.reject(starts, fn start ->
          {:ok, resolved} = DateTimeUtils.resolve_local(date, DateTime.to_time(start), user_tz)

          DateTime.to_date(start) == date and DateTime.compare(resolved, start) == :eq and
            Enum.all?(
              minutes(start, DateTime.add(start, duration, :minute)),
              &MapSet.member?(open, &1)
            )
        end)

      assert bad == [], "listed but not valid: #{inspect(bad)}"
      if starts != [], do: Process.put(@checked, Process.get(@checked) + 1)
    end

    assert Process.get(@checked) > 30, "too few runs listed anything"
  end

  property "with no interval, every window's own start is listed when it fits" do
    check all(
            date <- Gen.date(),
            tz <- Gen.zone(),
            duration <- member_of([30, 60, 240]),
            days <- Gen.week(Gen.any_window()),
            max_runs: 200
          ) do
      config = pure_config(days: days)
      {:ok, starts} = SlotGrid.starts_for_date(date, duration, tz, tz, config)
      open = open_minutes(days, tz, Date.range(Date.add(date, -3), Date.add(date, 3)))

      missing =
        for owner_date <- [Date.add(date, -1), date],
            %{is_available: true} = day <- [day_on(days, owner_date)],
            start = local(owner_date, day.start_time, tz),
            DateTime.to_date(start) == date,
            Enum.all?(
              minutes(start, DateTime.add(start, duration, :minute)),
              &MapSet.member?(open, &1)
            ),
            # Compared by label: in a repeated fall-back hour an earlier
            # instant with the same label is listed instead, by design.
            TimeSlots.format_datetime_slot(start) not in Enum.map(
              starts,
              &TimeSlots.format_datetime_slot/1
            ),
            do: start

      assert missing == []
    end
  end

  @complete :slot_grid_property_complete

  property "across zones, exactly the grid starts that pass the listing rules and fit are listed" do
    Process.put(@complete, 0)

    check all(
            date <- Gen.date(),
            owner_tz <- Gen.zone(),
            user_tz <- Gen.zone(),
            duration <- member_of([30, 60, 90, 240, 1440]),
            interval <- Gen.interval(),
            days <- Gen.week(Gen.any_window()),
            max_runs: 150
          ) do
      config = pure_config(days: days, interval: interval)
      {:ok, starts} = SlotGrid.starts_for_date(date, duration, owner_tz, user_tz, config)
      dates = Date.range(Date.add(date, -3), Date.add(date, 3))
      open = open_minutes(days, owner_tz, dates)

      expected =
        for(
          owner_date <- dates,
          %{is_available: true} = day <- [day_on(days, owner_date)],
          start <- model_grid(day, owner_date, duration, interval, owner_tz),
          local = DateTime.shift_zone!(start, user_tz),
          DateTime.to_date(local) == date,
          do: local
        )
        |> Enum.sort(DateTime)
        |> Enum.uniq_by(&TimeSlots.format_datetime_slot/1)
        |> Enum.filter(fn start ->
          local(date, DateTime.to_time(start), user_tz) == start and
            Enum.all?(
              minutes(start, DateTime.add(start, duration, :minute)),
              &MapSet.member?(open, &1)
            )
        end)

      assert Enum.map(starts, &DateTime.to_unix/1) == Enum.map(expected, &DateTime.to_unix/1)
      if expected != [], do: Process.put(@complete, Process.get(@complete) + 1)
    end

    assert Process.get(@complete) > 15, "too few runs listed anything"
  end

  # --- independent model: minutes, never intervals ---

  # Every minute (as a Unix minute) some window covers and no break blocks.
  # A break blocks clock time for every window, not only its own.
  defp open_minutes(days, tz, dates) do
    windows =
      for date <- dates, %{is_available: true} = day <- [day_on(days, date)], do: {date, day}

    open =
      for {date, day} <- windows,
          minute <- window_minutes(day, date, tz),
          into: MapSet.new(),
          do: minute

    blocked =
      for {date, day} <- windows,
          break <- day.breaks,
          minute <- break_minutes(break, day, date, tz),
          into: MapSet.new(),
          do: minute

    MapSet.difference(open, blocked)
  end

  defp window_minutes(day, date, tz) do
    minutes(local(date, day.start_time, tz), local(end_date(day, date), day.end_time, tz))
  end

  # The spec's rule restated: in an overnight window a break start before the
  # window's start is on the next day, and a break end at or before it is too.
  # Clipped to its own window.
  defp break_minutes(break, day, date, tz) do
    start_on =
      if day.ends_next_day and Time.compare(break.start_time, day.start_time) == :lt,
        do: Date.add(date, 1),
        else: date

    end_on =
      if day.ends_next_day and Time.compare(break.end_time, day.start_time) != :gt,
        do: Date.add(date, 1),
        else: date

    own = MapSet.new(window_minutes(day, date, tz))

    Enum.filter(
      minutes(local(start_on, break.start_time, tz), local(end_on, break.end_time, tz)),
      &MapSet.member?(own, &1)
    )
  end

  defp end_date(%{ends_next_day: true}, date), do: Date.add(date, 1)
  defp end_date(_day, date), do: date

  defp day_on(days, date), do: Enum.find(days, &(&1.day_of_week == Date.day_of_week(date)))

  defp local(date, time, tz) do
    {:ok, dt} = DateTimeUtils.resolve_local(date, time, tz)
    dt
  end

  defp minutes(from, to) do
    first = div(DateTime.to_unix(from), 60)
    last = div(DateTime.to_unix(to), 60) - 1
    if last < first, do: [], else: Enum.to_list(first..last)
  end

  # A window's grid restated a minute at a time: the first minute at or after
  # the window's start whose owner wall clock sits on the interval's boundary
  # (the interval itself when it divides the hour, else the hour), then every
  # step of elapsed time while still before the window's end.
  defp model_grid(day, date, duration, interval, tz) do
    from = local(date, day.start_time, tz)
    to = local(end_date(day, date), day.end_time, tz)
    first = if interval, do: first_on_boundary(from, interval, tz), else: from
    step = interval || duration

    first
    |> Stream.iterate(&DateTime.add(&1, step, :minute))
    |> Enum.take_while(&(DateTime.compare(&1, to) == :lt))
  end

  defp first_on_boundary(from, interval, tz) do
    boundary = if rem(60, interval) == 0, do: interval, else: 60

    from
    |> Stream.iterate(&DateTime.add(&1, 1, :minute))
    |> Enum.find(fn instant ->
      wall = DateTime.shift_zone!(instant, tz)
      rem(wall.hour * 60 + wall.minute, boundary) == 0
    end)
  end
end
