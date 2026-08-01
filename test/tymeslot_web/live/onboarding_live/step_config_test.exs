defmodule TymeslotWeb.OnboardingLive.StepConfigTest do
  @moduledoc """
  Tests for the StepConfig module, focusing on configuration options
  and helper functions for the onboarding flow.
  """

  use ExUnit.Case, async: true
  @moduletag :utils

  alias TymeslotWeb.OnboardingLive.StepConfig

  describe "buffer_time_values/0" do
    test "returns correct preset values for buffer time" do
      assert StepConfig.buffer_time_values() == [0, 15, 30, 45, 60]
    end

    test "returned values match buffer_time_options/0 values" do
      option_values = Enum.map(StepConfig.buffer_time_options(), fn {_label, value} -> value end)
      assert StepConfig.buffer_time_values() == option_values
    end
  end

  describe "advance_booking_values/0" do
    test "returns correct preset values for advance booking" do
      assert StepConfig.advance_booking_values() == [7, 14, 30, 90, 180, 365]
    end

    test "returned values match advance_booking_options/0 values" do
      option_values =
        Enum.map(StepConfig.advance_booking_options(), fn {_label, value} -> value end)

      assert StepConfig.advance_booking_values() == option_values
    end
  end

  describe "min_advance_values/0" do
    test "returns correct preset values for minimum advance notice" do
      assert StepConfig.min_advance_values() == [0, 1, 3, 6, 12, 24, 48]
    end

    test "returned values match min_advance_options/0 values" do
      option_values = Enum.map(StepConfig.min_advance_options(), fn {_label, value} -> value end)
      assert StepConfig.min_advance_values() == option_values
    end
  end

  describe "buffer_time_options/0" do
    test "returns labelled tuples for every preset" do
      assert StepConfig.buffer_time_options() == [
               {"No buffer", 0},
               {"15 min", 15},
               {"30 min", 30},
               {"45 min", 45},
               {"60 min", 60}
             ]
    end
  end

  describe "advance_booking_options/0" do
    test "returns labelled tuples for every preset" do
      assert StepConfig.advance_booking_options() == [
               {"1 week", 7},
               {"2 weeks", 14},
               {"1 month", 30},
               {"3 months", 90},
               {"6 months", 180},
               {"1 year", 365}
             ]
    end
  end

  describe "min_advance_options/0" do
    test "returns labelled tuples for every preset" do
      assert StepConfig.min_advance_options() == [
               {"No minimum", 0},
               {"1 hour", 1},
               {"3 hours", 3},
               {"6 hours", 6},
               {"12 hours", 12},
               {"24 hours", 24},
               {"48 hours", 48}
             ]
    end
  end
end
