defmodule Tymeslot.MeetingTypes.InputValidationPropertyTest do
  @moduledoc """
  Property-based tests for MeetingTypes.InputValidation boundary conditions.
  """
  use ExUnit.Case, async: true
  @moduletag :meeting_types
  use ExUnitProperties

  alias Tymeslot.MeetingTypes.InputValidation

  describe "validate_meeting_type_field(:duration, ...)" do
    property "valid durations (5..480, divisible by 5) always pass" do
      check all(n <- integer(1..96)) do
        duration = n * 5

        assert {:ok, _sanitized} =
                 InputValidation.validate_meeting_type_field(:duration, to_string(duration))
      end
    end

    property "durations below 5 always fail" do
      check all(n <- integer(-100..4)) do
        assert {:error, %{duration: _msg}} =
                 InputValidation.validate_meeting_type_field(:duration, to_string(n))
      end
    end

    property "durations above 480 always fail" do
      check all(n <- integer(481..10_000)) do
        assert {:error, %{duration: _msg}} =
                 InputValidation.validate_meeting_type_field(:duration, to_string(n))
      end
    end

    property "durations not divisible by 5 always fail" do
      check all(
              n <- integer(5..480),
              rem(n, 5) != 0
            ) do
        assert {:error, %{duration: "Duration must be divisible by 5 minutes"}} =
                 InputValidation.validate_meeting_type_field(:duration, to_string(n))
      end
    end
  end

  describe "validate_buffer_minutes/1" do
    property "valid buffer values (0..120) always pass" do
      check all(n <- integer(0..120)) do
        assert {:ok, ^n} = InputValidation.validate_buffer_minutes(to_string(n))
      end
    end

    property "values above 120 always fail" do
      check all(n <- integer(121..1000)) do
        assert {:error, _msg} = InputValidation.validate_buffer_minutes(to_string(n))
      end
    end

    property "negative values always fail" do
      check all(n <- integer(-1000..-1)) do
        assert {:error, _msg} = InputValidation.validate_buffer_minutes(to_string(n))
      end
    end
  end

  describe "validate_advance_booking_days/1" do
    property "valid days (1..365) always pass" do
      check all(n <- integer(1..365)) do
        assert {:ok, ^n} = InputValidation.validate_advance_booking_days(to_string(n))
      end
    end

    property "0 or negative always fails" do
      check all(n <- integer(-100..0)) do
        assert {:error, _msg} = InputValidation.validate_advance_booking_days(to_string(n))
      end
    end

    property "above 365 always fails" do
      check all(n <- integer(366..1000)) do
        assert {:error, _msg} = InputValidation.validate_advance_booking_days(to_string(n))
      end
    end
  end

  describe "validate_min_advance_hours/1" do
    property "valid hours (0..168) always pass" do
      check all(n <- integer(0..168)) do
        assert {:ok, ^n} = InputValidation.validate_min_advance_hours(to_string(n))
      end
    end

    property "above 168 always fails" do
      check all(n <- integer(169..1000)) do
        assert {:error, _msg} = InputValidation.validate_min_advance_hours(to_string(n))
      end
    end
  end
end
