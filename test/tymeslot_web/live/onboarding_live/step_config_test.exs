defmodule TymeslotWeb.OnboardingLive.StepConfigTest do
  @moduledoc """
  Tests for the StepConfig module, focusing on configuration options
  and helper functions for the onboarding flow.
  """

  use ExUnit.Case, async: true
  @moduletag :utils

  alias Tymeslot.Availability.AvailabilityScheduleSchema
  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.CustomInputModeHelper
  alias TymeslotWeb.OnboardingLive.StepConfig

  describe "the options the wizard offers against the list that validates them" do
    # The wizard's options and the dashboard availability card's tags were once
    # three independent literals validated against a fourth. A preset click the
    # validator does not recognise is treated as client tampering and silently
    # leaves the field in custom-input mode, so a value offered here that
    # `preset_value?/2` rejects is a live defect, not just untidiness.

    test "every buffer time option is a value preset_value?/2 accepts" do
      assert_options_validate(StepConfig.buffer_time_options(), :buffer_minutes)
    end

    test "every advance booking option is a value preset_value?/2 accepts" do
      assert_options_validate(StepConfig.advance_booking_options(), :advance_booking_days)
    end

    test "every minimum notice option is a value preset_value?/2 accepts" do
      assert_options_validate(StepConfig.min_advance_options(), :min_advance_hours)
    end

    test "custom_input_config/0 carries the same presets it validates against" do
      config = StepConfig.custom_input_config()

      refute Enum.empty?(config)

      assert Enum.reject(config, fn {_setting, %{field: field, presets: presets}} ->
               presets == CustomInputModeHelper.presets(field)
             end) == []
    end
  end

  describe "buffer_time_options/0" do
    test "returns labelled tuples for every preset" do
      assert StepConfig.buffer_time_options() == [
               {"No buffer", 0},
               {"5 min", 5},
               {"10 min", 10},
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
               {"2 months", 60},
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
               {"4 hours", 4},
               {"6 hours", 6},
               {"12 hours", 12},
               {"24 hours", 24},
               {"48 hours", 48},
               {"1 week", 168}
             ]
    end
  end

  describe "presets against the range the schema validates against" do
    # The presets and each slider's `default_custom` are plain literals — the
    # presets in `CustomInputModeHelper`, the defaults here — while the changeset
    # that validates what onboarding submits reads its bounds from
    # `Constraints`. Nothing ties the two together, so a
    # preset outside the range would render as a normal one-click choice and
    # then be rejected on submit, with the user blamed for a value we offered.

    test "every buffer time preset and the custom default are bookable" do
      range = Constraints.buffer_minutes_range()
      presets = CustomInputModeHelper.presets(:buffer_minutes)

      # Anchor: an empty preset list would make the rejection below vacuous.
      refute Enum.empty?(presets)
      assert Enum.reject(presets, &(&1 in range)) == []
      assert StepConfig.buffer_minutes_constraints().default_custom in range
    end

    test "every advance booking preset and the custom default are bookable" do
      range = Constraints.advance_booking_days_range()
      presets = CustomInputModeHelper.presets(:advance_booking_days)

      refute Enum.empty?(presets)
      assert Enum.reject(presets, &(&1 in range)) == []
      assert StepConfig.advance_booking_constraints().default_custom in range
    end

    test "every minimum notice preset and the custom default are bookable" do
      range = Constraints.min_advance_hours_range()
      presets = CustomInputModeHelper.presets(:min_advance_hours)

      refute Enum.empty?(presets)
      assert Enum.reject(presets, &(&1 in range)) == []
      assert StepConfig.min_advance_constraints().default_custom in range
    end
  end

  describe "presets against the defaults a new schedule is created with" do
    # A default the tags do not offer opens the setting in custom-input mode for
    # every new user, with no tag highlighted. That is how the card's
    # minimum-notice list was found to be missing 3, the schema's own default.

    test "every scheduling policy default is offered as a preset" do
      schedule = %AvailabilityScheduleSchema{}
      defaults = Enum.map(CustomInputModeHelper.fields(), &{&1, Map.fetch!(schedule, &1)})

      # Anchor: no fields would make the rejection below vacuous.
      refute Enum.empty?(defaults)

      assert Enum.reject(defaults, fn {field, value} ->
               CustomInputModeHelper.preset_value?(field, value)
             end) == []
    end
  end

  defp assert_options_validate(options, field) do
    values = Enum.map(options, fn {_label, value} -> value end)

    # Anchor: an empty option list would make the rejection below vacuous.
    refute Enum.empty?(values)
    assert values == CustomInputModeHelper.presets(field)
    assert Enum.reject(values, &CustomInputModeHelper.preset_value?(field, &1)) == []
  end
end
