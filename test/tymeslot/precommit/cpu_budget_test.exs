defmodule Tymeslot.Precommit.CpuBudgetTest do
  use ExUnit.Case, async: true

  @moduletag :dev_support

  alias Tymeslot.Precommit.CpuBudget

  describe "plan/2" do
    test "an idle 16-core host gets five partitions of three schedulers" do
      assert CpuBudget.plan(16) == %{partitions: 5, schedulers: 3}
    end

    test "never plans more than six partitions, however many cores are free" do
      assert CpuBudget.plan(64) == %{partitions: 6, schedulers: 10}
    end

    test "a busy host shrinks to fewer partitions rather than oversubscribing" do
      assert CpuBudget.plan(7) == %{partitions: 2, schedulers: 3}
    end

    test "fewer than three free cores runs a single partition" do
      assert CpuBudget.plan(2) == %{partitions: 1, schedulers: 2}
      assert CpuBudget.plan(1) == %{partitions: 1, schedulers: 2}
    end

    test "a forced partition count keeps the scheduler cap to the budget" do
      assert CpuBudget.plan(16, 8) == %{partitions: 8, schedulers: 2}
      assert CpuBudget.plan(16, 2) == %{partitions: 2, schedulers: 8}
    end
  end

  describe "parse_stat/1 and idle_between/2" do
    @stat_before """
    cpu  1000 0 500 8000 500 0 0 0 0 0
    cpu0 500 0 250 4000 250 0 0 0 0 0
    cpu1 500 0 250 4000 250 0 0 0 0 0
    intr 12345
    """

    # 400 ticks elapsed across both cores: 100 user, 300 idle (iowait counts as
    # idle, since a core waiting on disk is free to run a test).
    @stat_after """
    cpu  1100 0 500 8250 550 0 0 0 0 0
    cpu0 550 0 250 4125 275 0 0 0 0 0
    cpu1 550 0 250 4125 275 0 0 0 0 0
    intr 12400
    """

    test "counts idle cores between two readings" do
      assert {:ok, before} = CpuBudget.parse_stat(@stat_before)
      assert {:ok, later} = CpuBudget.parse_stat(@stat_after)

      assert before.cpus == 2
      # 300 of 400 ticks idle, on two cores
      assert CpuBudget.idle_between(before, later) == 2
    end

    test "a fully busy window leaves no idle cores" do
      {:ok, before} = CpuBudget.parse_stat(@stat_before)

      {:ok, later} =
        CpuBudget.parse_stat(String.replace(@stat_before, "cpu  1000", "cpu  1400"))

      assert CpuBudget.idle_between(before, later) == 0
    end

    test "unreadable contents are an error rather than a guess" do
      assert CpuBudget.parse_stat("") == :error
      assert CpuBudget.parse_stat("cpu  1 2 3\n") == :error
    end
  end
end
