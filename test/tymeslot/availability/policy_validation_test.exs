defmodule Tymeslot.Availability.PolicyValidationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :availability

  alias Tymeslot.Availability.AvailabilityScheduleSchema
  alias Tymeslot.Availability.PolicyValidation

  # Each field's bounds as the schedule's policy changeset enforces them.
  @bounds [
    buffer_before_minutes: {0, 120},
    buffer_after_minutes: {0, 120},
    advance_booking_days: {1, 365},
    min_advance_hours: {0, 168}
  ]

  for {field, {min, max}} <- @bounds do
    describe "validate(#{inspect(field)}, ...)" do
      property "accepts every value from #{min} to #{max}" do
        check all(n <- integer(unquote(min)..unquote(max))) do
          assert {:ok, ^n} = PolicyValidation.validate(unquote(field), to_string(n))
        end
      end

      test "refuses #{min - 1} and #{max + 1}" do
        assert {:error, low} = PolicyValidation.validate(unquote(field), "#{unquote(min) - 1}")
        assert low =~ "must be at least #{unquote(min)}"

        assert {:error, high} = PolicyValidation.validate(unquote(field), "#{unquote(max) + 1}")
        assert high =~ "cannot be more than #{unquote(max)}"
      end

      test "refuses a value that is not a whole number" do
        assert {:error, message} = PolicyValidation.validate(unquote(field), "lots")
        assert message =~ "must be a whole number"
      end
    end
  end

  test "names the setting a refusal is about" do
    assert {:error, "Buffer before cannot be more than 120"} =
             PolicyValidation.validate(:buffer_before_minutes, "121")

    assert {:error, "Buffer after cannot be more than 120"} =
             PolicyValidation.validate(:buffer_after_minutes, "121")
  end

  test "agrees with the policy changeset at every bound" do
    for {field, {min, max}} <- @bounds, value <- [min - 1, min, max, max + 1] do
      changeset =
        AvailabilityScheduleSchema.policy_changeset(%AvailabilityScheduleSchema{}, %{
          field => value
        })

      assert match?({:ok, _value}, PolicyValidation.validate(field, to_string(value))) ==
               changeset.valid?,
             "#{field} = #{value}"
    end
  end

  test "refuses in the current locale" do
    Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
      assert {:error, message} = PolicyValidation.validate(:advance_booking_days, "0")
      refute message =~ "must be at least"
    end)
  end
end
