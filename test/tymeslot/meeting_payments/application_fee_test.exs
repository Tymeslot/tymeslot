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
  end
end
