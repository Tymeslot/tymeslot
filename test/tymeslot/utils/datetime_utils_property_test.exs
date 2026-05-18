defmodule Tymeslot.Utils.DateTimeUtilsPropertyTest do
  @moduledoc """
  Property-based tests for DateTimeUtils parsing and formatting round-trips.
  """
  use ExUnit.Case, async: true
  @moduletag :utils
  use ExUnitProperties

  alias Tymeslot.Utils.DateTimeUtils
  alias Tymeslot.Utils.DateTimeUtils.Display

  describe "format_time_for_display/1 and parse_time_string/1 round-trip" do
    property "round-trip: parse(format(time)) recovers the original time" do
      check all(
              hour <- integer(0..23),
              minute <- integer(0..59)
            ) do
        time = Time.new!(hour, minute, 0)
        formatted = Display.format_time_for_display(time)
        assert {:ok, parsed} = DateTimeUtils.parse_time_string(formatted)

        assert parsed == time,
               "Round-trip failed: #{time} -> #{inspect(formatted)} -> #{inspect(parsed)}"
      end
    end

    property "format always produces AM/PM suffix" do
      check all(
              hour <- integer(0..23),
              minute <- integer(0..59)
            ) do
        time = Time.new!(hour, minute, 0)
        formatted = Display.format_time_for_display(time)

        assert String.ends_with?(formatted, " AM") or String.ends_with?(formatted, " PM")
      end
    end

    property "AM hours are 0-11, PM hours are 12-23" do
      check all(
              hour <- integer(0..23),
              minute <- integer(0..59)
            ) do
        time = Time.new!(hour, minute, 0)
        formatted = Display.format_time_for_display(time)

        if hour < 12 do
          assert String.ends_with?(formatted, " AM")
        else
          assert String.ends_with?(formatted, " PM")
        end
      end
    end
  end

  describe "parse_hhmm/1" do
    property "round-trip: valid HH:MM strings parse and reconstruct" do
      check all(
              hour <- integer(0..23),
              minute <- integer(0..59)
            ) do
        hhmm =
          String.pad_leading(to_string(hour), 2, "0") <>
            ":" <> String.pad_leading(to_string(minute), 2, "0")

        assert {:ok, time} = DateTimeUtils.parse_hhmm(hhmm)
        assert time.hour == hour
        assert time.minute == minute
        assert time.second == 0
      end
    end
  end

  describe "parse_time_string/1 robustness" do
    property "never crashes on arbitrary strings" do
      check all(s <- string(:printable)) do
        result = DateTimeUtils.parse_time_string(s)
        assert match?({:ok, _time}, result) or match?({:error, _reason}, result)
      end
    end

    property "case-insensitive AM/PM parsing" do
      check all(
              hour <- integer(1..12),
              minute <- integer(0..59),
              period <- member_of(["am", "AM", "Am", "aM", "pm", "PM", "Pm", "pM"])
            ) do
        time_str = "#{hour}:#{String.pad_leading(to_string(minute), 2, "0")} #{period}"
        assert {:ok, _time} = DateTimeUtils.parse_time_string(time_str)
      end
    end
  end
end
