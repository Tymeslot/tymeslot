defmodule Tymeslot.BookingSeries.RuleTest do
  @moduledoc """
  How a series' rhythm reads (`BookingSeries.describe_rule/3`), for a booked
  series from its first session and for a type before anyone has booked.
  """

  use ExUnit.Case, async: true

  @moduletag :bookings

  alias Tymeslot.BookingSeries
  alias Tymeslot.BookingSeries.Dates
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  defp series(frequency, interval),
    do: %SeriesSchema{mode: :recurring, frequency: frequency, interval: interval}

  defp type(frequency, interval),
    do: %MeetingTypeSchema{
      series_mode: :recurring,
      series_frequency: frequency,
      series_interval: interval
    }

  # Thursday 12 November 2026, 17:00 in Berlin.
  defp thursday(day \\ 12),
    do: DateTime.new!(Date.new!(2026, 11, day), ~T[17:00:00], "Europe/Berlin")

  defp rule(subject, opts \\ []),
    do: BookingSeries.describe_rule(subject, "en", Keyword.put_new(opts, :time_format, "24h"))

  describe "a series, from its first session" do
    test "weekly" do
      assert rule(series(:weekly, 1), first_start: thursday()) ==
               "Every week on Thursday at 17:00"
    end

    test "every 2 weeks" do
      assert rule(series(:weekly, 2), first_start: thursday()) ==
               "Every 2 weeks on Thursday at 17:00"
    end

    test "daily" do
      assert rule(series(:daily, 1), first_start: thursday()) == "Every day at 17:00"
      assert rule(series(:daily, 3), first_start: thursday()) == "Every 3 days at 17:00"
    end

    test "monthly on the second Thursday" do
      assert rule(series(:monthly, 1), first_start: thursday(12)) ==
               "Every month on the second Thursday at 17:00"
    end

    test "monthly from a fifth weekday reads as the last one" do
      # Friday 30 October 2026 is the month's fifth Friday.
      first = DateTime.new!(~D[2026-10-30], ~T[09:30:00], "Europe/Berlin")

      assert rule(series(:monthly, 2), first_start: first) ==
               "Every 2 months on the last Friday at 09:30"
    end

    test "the day and time are read in the zone the first start is in" do
      in_new_york = DateTime.shift_zone!(thursday(), "America/New_York")

      assert rule(series(:weekly, 1), first_start: in_new_york) ==
               "Every week on Thursday at 11:00"
    end

    test "the locale's clock without a chosen one" do
      assert BookingSeries.describe_rule(series(:weekly, 1), "en", first_start: thursday()) ==
               "Every week on Thursday at 05:00 PM"
    end

    test "a series without its first start reads like its type" do
      assert rule(series(:weekly, 2)) == "Every 2 weeks"
    end

    test "a flexible series has no rhythm" do
      assert rule(%SeriesSchema{mode: :flexible}, first_start: thursday()) == nil
    end
  end

  describe "a type" do
    test "names the rhythm alone" do
      assert rule(type(:weekly, 1)) == "Every week"
      assert rule(type(:weekly, 2)) == "Every 2 weeks"
      assert rule(type(:daily, 1)) == "Every day"
      assert rule(type(:monthly, 1)) == "Every month on the same weekday"
      assert rule(type(:monthly, 3)) == "Every 3 months on the same weekday"
    end

    test "a type that offers no recurring series has none" do
      assert rule(%MeetingTypeSchema{series_mode: :flexible}) == nil
      assert rule(%MeetingTypeSchema{series_mode: nil}) == nil
    end
  end

  describe "a series, from its sessions as they now stand" do
    @zone "Europe/Berlin"

    defp at(date, time), do: DateTime.shift_zone!(DateTime.new!(date, time, @zone), "Etc/UTC")

    # The starts the series' own rule puts its sessions on.
    defp starts(frequency, interval, first, count),
      do: Dates.recurring_starts(first, frequency, interval, count, @zone)

    defp booked(frequency, interval, first),
      do: %{series(frequency, interval) | first_start_at: first}

    defp sessions_rule(series, starts),
      do:
        BookingSeries.describe_rule_for_sessions(series, starts, "en", @zone, time_format: "24h")

    test "sessions on the rule read with their day and time" do
      first = at(~D[2026-11-12], ~T[17:00:00])

      assert sessions_rule(booked(:weekly, 1, first), starts(:weekly, 1, first, 4)) ==
               "Every week on Thursday at 17:00"
    end

    test "a daily series keeps its phrase over different weekdays" do
      first = at(~D[2026-11-12], ~T[17:00:00])

      assert sessions_rule(booked(:daily, 1, first), starts(:daily, 1, first, 5)) ==
               "Every day at 17:00"
    end

    test "a series from a fifth weekday reads as the last one in a month without a fifth" do
      # Friday 30 January 2026 is a fifth Friday; February's last is the 27th,
      # its fourth.
      first = at(~D[2026-01-30], ~T[09:30:00])
      starts = starts(:monthly, 1, first, 3)

      assert Enum.map(starts, &DateTime.to_date/1) == [
               ~D[2026-01-30],
               ~D[2026-02-27],
               ~D[2026-03-27]
             ]

      assert sessions_rule(booked(:monthly, 1, first), starts) ==
               "Every month on the last Friday at 09:30"
    end

    test "without first_start_at the earliest session says the series is held on the last weekday" do
      first = at(~D[2026-01-30], ~T[09:30:00])

      assert sessions_rule(series(:monthly, 1), starts(:monthly, 1, first, 3)) ==
               "Every month on the last Friday at 09:30"
    end

    test "a series from a fourth weekday that was its month's last stays on the fourth" do
      # Friday 27 February 2026 is both the fourth and the last; April's
      # fourth Friday (the 24th) is not its last.
      first = at(~D[2026-02-27], ~T[09:30:00])
      starts = starts(:monthly, 1, first, 3)
      assert DateTime.to_date(List.last(starts)) == ~D[2026-04-24]

      assert sessions_rule(booked(:monthly, 1, first), starts) ==
               "Every month on the fourth Friday at 09:30"
    end

    test "a moved session leaves the rhythm alone" do
      first = at(~D[2026-11-12], ~T[17:00:00])
      [one, two, three] = starts(:weekly, 1, first, 3)
      moved = DateTime.add(two, 1, :hour)

      assert sessions_rule(booked(:weekly, 1, first), [one, moved, three]) == "Every week"
    end

    test "a session moved off the last weekday in a series held on it leaves the rhythm alone" do
      first = at(~D[2026-01-30], ~T[09:30:00])
      # Friday 22 May 2026 is May's fourth Friday; its last is the 29th.
      moved = at(~D[2026-05-22], ~T[09:30:00])

      assert sessions_rule(booked(:monthly, 1, first), [first, moved]) ==
               "Every month on the same weekday"
    end

    test "a flexible series has no rhythm" do
      first = at(~D[2026-11-12], ~T[17:00:00])
      assert sessions_rule(%SeriesSchema{mode: :flexible}, [first]) == nil
    end
  end
end
