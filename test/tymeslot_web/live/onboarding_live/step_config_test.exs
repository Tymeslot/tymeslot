defmodule TymeslotWeb.OnboardingLive.StepConfigTest do
  @moduledoc """
  Tests for the StepConfig module, focusing on configuration options
  and helper functions for the onboarding flow.
  """

  use ExUnit.Case, async: true
  @moduletag :utils

  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.OnboardingLive.StepConfig

  describe "buffer_time_values/0" do
    test "returned values match buffer_time_options/0 values" do
      option_values = Enum.map(StepConfig.buffer_time_options(), fn {_label, value} -> value end)
      assert StepConfig.buffer_time_values() == option_values
    end
  end

  describe "advance_booking_values/0" do
    test "returned values match advance_booking_options/0 values" do
      option_values =
        Enum.map(StepConfig.advance_booking_options(), fn {_label, value} -> value end)

      assert StepConfig.advance_booking_values() == option_values
    end
  end

  describe "min_advance_values/0" do
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

  describe "presets against the range the schema validates against" do
    # The presets and each slider's `default_custom` are plain literals in
    # StepConfig, while the changeset that validates what onboarding submits
    # reads its bounds from `Constraints`. Nothing tied the two together, so a
    # preset outside the range would render as a normal one-click choice and
    # then be rejected on submit, with the user blamed for a value we offered.

    test "every buffer time preset and the custom default are bookable" do
      range = Constraints.buffer_minutes_range()
      presets = StepConfig.buffer_time_values()

      # Anchor: an empty preset list would make the rejection below vacuous.
      refute Enum.empty?(presets)
      assert Enum.reject(presets, &(&1 in range)) == []
      assert StepConfig.buffer_minutes_constraints().default_custom in range
    end

    test "every advance booking preset and the custom default are bookable" do
      range = Constraints.advance_booking_days_range()
      presets = StepConfig.advance_booking_values()

      refute Enum.empty?(presets)
      assert Enum.reject(presets, &(&1 in range)) == []
      assert StepConfig.advance_booking_constraints().default_custom in range
    end

    test "every minimum notice preset and the custom default are bookable" do
      range = Constraints.min_advance_hours_range()
      presets = StepConfig.min_advance_values()

      refute Enum.empty?(presets)
      assert Enum.reject(presets, &(&1 in range)) == []
      assert StepConfig.min_advance_constraints().default_custom in range
    end
  end
end
