defmodule Tymeslot.Availability.BreaksTest do
  use Tymeslot.DataCase, async: true

  @moduletag :availability

  alias Tymeslot.Availability.AvailabilityBreakSchema
  alias Tymeslot.Availability.Breaks

  setup do
    day =
      insert(:weekly_availability,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )

    %{day: day}
  end

  describe "add_break/4" do
    test "refuses a break outside the hours with one message per end", %{day: day} do
      assert {:error, changeset} = Breaks.add_break(day.id, ~T[08:00:00], ~T[18:00:00], nil)

      assert errors_on(changeset).start_time == ["must be within work hours"]
      assert errors_on(changeset).end_time == ["must be within work hours"]
    end

    test "refuses a break on a day that no longer exists" do
      assert {:error, changeset} = Breaks.add_break(-1, ~T[12:00:00], ~T[13:00:00], nil)
      assert errors_on(changeset).base == ["Work hours not found"]
    end
  end

  describe "outside_hours/2" do
    test "keeps the breaks that leave the hours, at either end or across midnight" do
      hours = %{start_time: ~T[09:00:00], end_time: ~T[12:00:00], ends_next_day: false}
      inside = %{start_time: ~T[10:00:00], end_time: ~T[10:30:00]}
      early = %{start_time: ~T[08:30:00], end_time: ~T[09:30:00]}
      late = %{start_time: ~T[11:45:00], end_time: ~T[12:15:00]}

      assert Breaks.outside_hours([inside, early, late], hours) == [early, late]
    end

    test "reads hours that end the next day through midnight" do
      hours = %{start_time: ~T[22:00:00], end_time: ~T[02:00:00], ends_next_day: true}
      across = %{start_time: ~T[23:30:00], end_time: ~T[00:30:00]}

      assert Breaks.outside_hours([across], hours) == []
    end

    test "a day without hours has nothing outside them" do
      assert Breaks.outside_hours([%{start_time: ~T[10:00:00], end_time: ~T[11:00:00]}], %{
               start_time: nil,
               end_time: nil
             }) == []
    end
  end

  describe "replace_breaks/2" do
    test "replaces the day's breaks with the copies", %{day: day} do
      insert(:availability_break, weekly_availability: day, label: "Old")

      copies = [
        %{start_time: ~T[12:00:00], end_time: ~T[12:30:00], label: "Lunch", sort_order: 0},
        %{start_time: ~T[15:00:00], end_time: ~T[15:15:00], label: nil, sort_order: 1}
      ]

      assert :ok = Breaks.replace_breaks(day, copies)

      assert day.id |> breaks_for() |> Enum.map(&{&1.start_time, &1.label}) == [
               {~T[12:00:00], "Lunch"},
               {~T[15:00:00], nil}
             ]
    end

    # A copy is held to the same hours as a break added by hand, rather than
    # bulk-inserted past them.
    test "refuses a copy outside the day's hours", %{day: day} do
      copies = [%{start_time: ~T[18:00:00], end_time: ~T[18:30:00], label: nil, sort_order: 0}]

      assert {:error, {:break_outside_hours, %{id: day_id}, %{start_time: ~T[18:00:00]}}} =
               Breaks.replace_breaks(day, copies)

      assert day_id == day.id
    end
  end

  defp breaks_for(day_id) do
    AvailabilityBreakSchema
    |> where([b], b.weekly_availability_id == ^day_id)
    |> order_by([b], asc: b.start_time)
    |> Repo.all()
  end
end
