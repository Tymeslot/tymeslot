defmodule Tymeslot.Workers.SnoozePolicyTest do
  use ExUnit.Case, async: true

  @moduletag :workers

  alias Tymeslot.Workers.SnoozePolicy

  describe "snooze_or_exhaust/2" do
    test "snoozes for base_seconds while under the attempt budget" do
      assert {:snooze, 120} =
               SnoozePolicy.snooze_or_exhaust(1, max_snoozes: 10, base_seconds: 120)
    end

    test "adds jitter within the given bound" do
      assert {:snooze, seconds} =
               SnoozePolicy.snooze_or_exhaust(1,
                 max_snoozes: 10,
                 base_seconds: 120,
                 jitter_seconds: 30
               )

      assert seconds > 120
      assert seconds <= 150
    end

    test "returns :exhausted once the attempt budget is spent" do
      assert :exhausted = SnoozePolicy.snooze_or_exhaust(10, max_snoozes: 10, base_seconds: 120)
      assert :exhausted = SnoozePolicy.snooze_or_exhaust(11, max_snoozes: 10, base_seconds: 120)
    end

    test "still snoozes on the attempt right before the budget" do
      assert {:snooze, _seconds} =
               SnoozePolicy.snooze_or_exhaust(9, max_snoozes: 10, base_seconds: 120)
    end
  end
end
