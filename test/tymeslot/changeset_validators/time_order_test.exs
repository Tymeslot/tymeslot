defmodule Tymeslot.ChangesetValidators.TimeOrderTest do
  use ExUnit.Case, async: true

  alias Tymeslot.ChangesetValidators.TimeOrder

  @moduletag :unit

  defmodule TimeSlot do
    use Ecto.Schema

    embedded_schema do
      field(:start_time, :time)
      field(:end_time, :time)
    end
  end

  defmodule DateTimeSlot do
    use Ecto.Schema

    embedded_schema do
      field(:start_time, :utc_datetime)
      field(:end_time, :utc_datetime)
    end
  end

  defp time_changeset(start_time, end_time) do
    Ecto.Changeset.change(%TimeSlot{}, %{start_time: start_time, end_time: end_time})
  end

  defp datetime_changeset(start_time, end_time) do
    Ecto.Changeset.change(%DateTimeSlot{}, %{start_time: start_time, end_time: end_time})
  end

  describe "validate_time_order/3 with Time" do
    test "valid when end_time is after start_time" do
      changeset = time_changeset(~T[09:00:00], ~T[17:00:00])
      result = TimeOrder.validate_time_order(changeset, :start_time, :end_time)
      assert result.valid?
    end

    test "invalid when end_time equals start_time" do
      changeset = time_changeset(~T[09:00:00], ~T[09:00:00])
      result = TimeOrder.validate_time_order(changeset, :start_time, :end_time)
      refute result.valid?
      assert {:end_time, {"must be after start time", []}} in result.errors
    end

    test "invalid when end_time is before start_time" do
      changeset = time_changeset(~T[17:00:00], ~T[09:00:00])
      result = TimeOrder.validate_time_order(changeset, :start_time, :end_time)
      refute result.valid?
    end

    test "valid when start_time is nil" do
      changeset = time_changeset(nil, ~T[17:00:00])
      result = TimeOrder.validate_time_order(changeset, :start_time, :end_time)
      assert result.valid?
    end

    test "valid when end_time is nil" do
      changeset = time_changeset(~T[09:00:00], nil)
      result = TimeOrder.validate_time_order(changeset, :start_time, :end_time)
      assert result.valid?
    end
  end

  describe "validate_time_order/3 with DateTime" do
    test "valid when end_time is after start_time" do
      changeset =
        datetime_changeset(~U[2026-01-01 09:00:00Z], ~U[2026-01-01 17:00:00Z])

      result = TimeOrder.validate_time_order(changeset, :start_time, :end_time)
      assert result.valid?
    end

    test "invalid when end_time is before start_time" do
      changeset =
        datetime_changeset(~U[2026-01-01 17:00:00Z], ~U[2026-01-01 09:00:00Z])

      result = TimeOrder.validate_time_order(changeset, :start_time, :end_time)
      refute result.valid?
    end
  end

  describe "validate_time_order/4 with custom message" do
    test "uses custom error message" do
      changeset = time_changeset(~T[17:00:00], ~T[09:00:00])

      result =
        TimeOrder.validate_time_order(changeset, :start_time, :end_time,
          message: "end must follow start"
        )

      assert {:end_time, {"end must follow start", []}} in result.errors
    end
  end
end
