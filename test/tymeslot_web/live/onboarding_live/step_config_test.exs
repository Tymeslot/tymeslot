defmodule TymeslotWeb.OnboardingLive.StepConfigTest do
  @moduletag :utils
  @moduledoc """
  @moduletag :utils
  Tests for the StepConfig module, focusing on configuration options
  and helper functions for the onboarding flow.
  """

  use ExUnit.Case, async: true

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
    test "returns tuples with labels and values" do
      options = StepConfig.buffer_time_options()
      assert length(options) == 5

      # Check structure
      Enum.each(options, fn option ->
        assert {label, value} = option
        assert is_binary(label)
        assert is_integer(value)
      end)
    end
  end

  describe "advance_booking_options/0" do
    test "returns tuples with labels and values" do
      options = StepConfig.advance_booking_options()
      assert length(options) == 6

      # Check structure
      Enum.each(options, fn option ->
        assert {label, value} = option
        assert is_binary(label)
        assert is_integer(value)
      end)
    end
  end

  describe "min_advance_options/0" do
    test "returns tuples with labels and values" do
      options = StepConfig.min_advance_options()
      assert length(options) == 7

      # Check structure
      Enum.each(options, fn option ->
        assert {label, value} = option
        assert is_binary(label)
        assert is_integer(value)
      end)
    end
  end
end
