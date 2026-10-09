defmodule Tymeslot.Availability.IntervalsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :availability
  @moduletag :unit

  alias Tymeslot.Availability.Intervals

  defp at(hour), do: DateTime.add(~U[2027-06-14 00:00:00Z], hour * 3600, :second)
  defp iv(from, to), do: {at(from), at(to)}

  describe "merge/1" do
    test "joins touching and overlapping intervals and drops empty ones" do
      assert Intervals.merge([iv(22, 26), iv(25, 33), iv(40, 40), iv(0, 2)]) ==
               [iv(0, 2), iv(22, 33)]
    end

    test "joins intervals that only touch, so consecutive 24-hour days become one stretch" do
      assert Intervals.merge([iv(24, 48), iv(0, 24), iv(48, 72)]) == [iv(0, 72)]
    end

    test "compares instants, not wall clocks" do
      # 10:00 in London (BST) is 09:00 UTC, so it touches an interval ending
      # at 09:00 UTC although the wall clocks read 10:00 and 09:00.
      london = DateTime.new!(~D[2027-06-14], ~T[10:00:00], "Europe/London")
      assert Intervals.merge([{london, at(12)}, iv(8, 9)]) == [{at(8), at(12)}]
    end
  end

  describe "subtract/2" do
    test "cuts blocked time out, keeping touching edges free" do
      assert Intervals.subtract([iv(22, 28)], [iv(25, 26), iv(27, 30)]) == [
               iv(22, 25),
               iv(26, 27)
             ]
    end

    test "a block covering everything leaves nothing" do
      assert Intervals.subtract([iv(9, 17)], [iv(0, 24)]) == []
    end
  end

  describe "clip/2" do
    test "keeps only the part inside the bounds" do
      assert Intervals.clip([iv(8, 10), iv(16, 18), iv(20, 21)], iv(9, 17)) == [
               iv(9, 10),
               iv(16, 17)
             ]
    end
  end

  describe "covers?/3" do
    test "is true only when one interval holds the whole range" do
      free = [iv(22, 25), iv(26, 28)]

      assert Intervals.covers?(free, at(22), at(25))
      refute Intervals.covers?(free, at(24), at(27))
      refute Intervals.covers?(free, at(21), at(23))
    end
  end

  property "subtract leaves exactly the hours that are open and not blocked" do
    check all(
            open <- list_of(tuple({integer(0..48), integer(1..12)}), max_length: 4),
            blocked <- list_of(tuple({integer(0..48), integer(1..6)}), max_length: 4)
          ) do
      to_iv = fn {from, len} -> iv(from, from + len) end
      free = Intervals.subtract(Enum.map(open, to_iv), Enum.map(blocked, to_iv))

      for hour <- 0..60 do
        in_open = Enum.any?(open, fn {from, len} -> hour >= from and hour < from + len end)
        in_blocked = Enum.any?(blocked, fn {from, len} -> hour >= from and hour < from + len end)

        assert Intervals.covers?(free, at(hour), at(hour + 1)) == (in_open and not in_blocked),
               "hour #{hour}: open=#{inspect(open)} blocked=#{inspect(blocked)}"
      end
    end
  end
end
