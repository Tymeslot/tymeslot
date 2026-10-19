defmodule Tymeslot.MeetingTypes.InputValidationPropertyTest do
  @moduledoc """
  Property-based tests for MeetingTypes.InputValidation boundary conditions.
  """
  use ExUnit.Case, async: true
  @moduletag :meeting_types
  use ExUnitProperties

  alias Tymeslot.MeetingTypes.InputValidation

  describe "validate_field(:duration, ...)" do
    property "valid durations (5..1440, divisible by 5) always pass" do
      check all(n <- integer(1..288)) do
        duration = n * 5

        assert {:ok, _sanitized} =
                 InputValidation.validate_field(:duration, to_string(duration), %{})
      end
    end

    property "durations below 5 always fail" do
      check all(n <- integer(-100..4)) do
        assert {:error, %{duration: _msg}} =
                 InputValidation.validate_field(:duration, to_string(n), %{})
      end
    end

    property "durations above 1440 always fail" do
      check all(n <- integer(1441..10_000)) do
        assert {:error, %{duration: _msg}} =
                 InputValidation.validate_field(:duration, to_string(n), %{})
      end
    end

    property "durations not divisible by 5 always fail" do
      check all(
              n <- integer(5..1440),
              rem(n, 5) != 0
            ) do
        assert {:error, %{duration: "Duration must be a multiple of 5 minutes"}} =
                 InputValidation.validate_field(:duration, to_string(n), %{})
      end
    end
  end
end
