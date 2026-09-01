defmodule Tymeslot.Workers.SnoozePolicyTest do
  use ExUnit.Case, async: true

  @moduletag :workers

  alias Oban.Job
  alias Tymeslot.Workers.SnoozePolicy

  describe "executions/1" do
    test "counts a job that has never snoozed by its attempt alone" do
      assert SnoozePolicy.executions(%Job{attempt: 3, meta: %{}}) == 3
    end

    test "counts the same executions however Oban splits them across the 2.24 boundary" do
      # The same nine runs of one job, five of them genuine attempts and four
      # of them snoozes, as each Oban version records it. Up to 2.23 a snooze
      # stayed in `attempt`; from 2.24 it is rolled out of `attempt` and into
      # `meta["snoozed"]`. A bound measured on this number is unmoved by the
      # bump; one measured on `attempt` silently loses four of the nine.
      assert SnoozePolicy.executions(%Job{attempt: 9, meta: %{}}) == 9
      assert SnoozePolicy.executions(%Job{attempt: 5, meta: %{"snoozed" => 4}}) == 9
    end

    test "ignores a snooze count that is not a usable number" do
      # `meta` is a JSONB map any caller may write, and a job that cannot be
      # counted must still run rather than die on an ArithmeticError.
      assert SnoozePolicy.executions(%Job{attempt: 2, meta: %{"snoozed" => "lots"}}) == 2
    end
  end

  describe "snooze_or_exhaust/2" do
    test "snoozes for base_seconds while under the execution budget" do
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

    test "returns :exhausted once the execution budget is spent" do
      assert :exhausted = SnoozePolicy.snooze_or_exhaust(10, max_snoozes: 10, base_seconds: 120)
      assert :exhausted = SnoozePolicy.snooze_or_exhaust(11, max_snoozes: 10, base_seconds: 120)
    end

    test "still snoozes on the execution right before the budget" do
      assert {:snooze, _seconds} =
               SnoozePolicy.snooze_or_exhaust(9, max_snoozes: 10, base_seconds: 120)
    end
  end
end
