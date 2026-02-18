defmodule Tymeslot.Utils.TimezoneUtilsTest do
  use ExUnit.Case, async: true

  @moduletag :utils

  alias Tymeslot.Utils.TimezoneUtils

  describe "format_duration/1" do
    test "formats duration string" do
      assert TimezoneUtils.format_duration("15min") == "15 minutes"
      assert TimezoneUtils.format_duration("30min") == "30 minutes"
      assert TimezoneUtils.format_duration("60min") == "1 hour"
      assert TimezoneUtils.format_duration("90min") == "1.5 hours"
      assert TimezoneUtils.format_duration("120min") == "2 hours"
    end

    test "formats duration integer" do
      assert TimezoneUtils.format_duration(15) == "15 minutes"
      assert TimezoneUtils.format_duration(30) == "30 minutes"
      assert TimezoneUtils.format_duration(60) == "1 hour"
      assert TimezoneUtils.format_duration(90) == "1.5 hours"
      assert TimezoneUtils.format_duration(120) == "2 hours"
    end

    test "returns unknown for invalid inputs" do
      assert TimezoneUtils.format_duration("invalid") == "Unknown duration"
      assert TimezoneUtils.format_duration(nil) == "Unknown duration"
    end
  end
end
