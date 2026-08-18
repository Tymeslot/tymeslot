defmodule Tymeslot.MeetingPayments.ApplicationFeeTest do
  use ExUnit.Case, async: true

  @moduletag :payments
  @moduletag :unit

  alias Tymeslot.MeetingPayments.ApplicationFee

  describe "calculate/2" do
    test "0 bp returns 0" do
      assert 0 = ApplicationFee.calculate(5000, 0)
    end

    test "50 bp on 5000 returns 25" do
      assert 25 = ApplicationFee.calculate(5000, 50)
    end

    test "ceiling rounding — 51 cents at 50 bp returns 1 (cent floor)" do
      # 51 * 50 / 10_000 = 0.255 -> ceiling = 1, applied via cent floor
      assert 1 = ApplicationFee.calculate(51, 50)
    end

    test "0 cents returns 0 regardless of bp" do
      assert 0 = ApplicationFee.calculate(0, 50)
    end

    test "ceiling on 200 cents at 33 bp returns 1 (0.66 -> 1)" do
      assert 1 = ApplicationFee.calculate(200, 33)
    end

    test "integer ceiling matches float ceiling across a range of values" do
      # Verify the integer formula agrees with the float-based ceiling for all
      # combinations in a representative range, confirming no off-by-one divergence
      # from IEEE-754 rounding in the integer path.
      for price <- 1..500, bp <- [1, 33, 50, 100, 150, 200, 500] do
        float_ceil = ceil(price * bp / 10_000.0)
        expected = max(float_ceil, 1)

        assert ApplicationFee.calculate(price, bp) == expected,
               "mismatch at price=#{price} bp=#{bp}"
      end
    end

    test "rounds up just past a whole cent and stays exact on one" do
      # `calculate/2` is pure integer arithmetic — there is no float path to
      # diverge from. These are the two boundaries either side of a whole cent.
      #
      # Just over: 3 * 3334 = 10_002 → (10_002 + 9_999) div 10_000 = 2.
      assert ApplicationFee.calculate(3, 3334) == 2

      # Exactly on: 1 * 10_000 → (10_000 + 9_999) div 10_000 = 1, not 2.
      assert ApplicationFee.calculate(1, 10_000) == 1
    end
  end
end
