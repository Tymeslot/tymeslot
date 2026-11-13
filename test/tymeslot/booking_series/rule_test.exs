defmodule Tymeslot.BookingSeries.RuleTest do
  @moduledoc """
  How a series' rhythm reads (`BookingSeries.describe_rule/3`), for a booked
  series from its first session and for a type before anyone has booked.
  """

  use ExUnit.Case, async: true

  @moduletag :bookings

  alias Tymeslot.BookingSeries
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
end
