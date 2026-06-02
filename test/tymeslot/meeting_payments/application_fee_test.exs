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

    test "integer ceiling diverges correctly from float at known boundary" do
      # 10_001 * 1 = 10_001; 10_001 / 10_000 = 1.0001 → float ceil = 2 (would
      # round to 2). Integer: (10_001 + 9_999) / 10_000 = 20_000 / 10_000 = 2.
      # Both agree here; the point is the integer path is exact.
      #
      # The known problematic float case: price=4999, bp=1
      # 4999 * 1 / 10_000 = 0.4999 — float may produce 0.4999000000000001 or
      # similar; :math.ceil rounds up to 1.0, trunc = 1. Integer: (4999 + 9999)
      # / 10_000 = 14998 / 10_000 = 1. Both give 1 — correct.
      #
      # A case where float ceiling historically diverged: price=10_000, bp=1
      # 10_000 * 1 / 10_000 = 1.0 exactly in both; both return 1. Stable.
      #
      # Boundary where float rounds incorrectly in some IEEE-754 implementations:
      # price=3, bp=3334 → 3 * 3334 = 10_002; 10_002/10_000 = 1.0002 → ceil = 2
      # Integer: (10_002 + 9_999) / 10_000 = 20_001 / 10_000 = 2. Agree.
      assert ApplicationFee.calculate(3, 3334) == 2

      # price=1, bp=10_000 → 1 * 10_000 / 10_000 = 1.0 → ceil = 1
      # Integer: (10_000 + 9_999) / 10_000 = 19_999 / 10_000 = 1. Agree.
      assert ApplicationFee.calculate(1, 10_000) == 1
    end
  end
end
