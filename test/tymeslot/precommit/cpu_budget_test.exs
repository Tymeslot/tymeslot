defmodule Tymeslot.Precommit.CpuBudgetTest do
  use ExUnit.Case, async: true

  @moduletag :dev_support

  alias Tymeslot.Precommit.CpuBudget

  describe "plan/2" do
    test "a 16-core allowance gets five partitions of three schedulers" do
      assert CpuBudget.plan(16) == %{partitions: 5, schedulers: 3}
    end

    test "never plans more than six partitions, however many cores are allowed" do
      assert CpuBudget.plan(64) == %{partitions: 6, schedulers: 10}
    end

    test "a smaller allowance (a CPU quota) shrinks to fewer partitions" do
      assert CpuBudget.plan(7) == %{partitions: 2, schedulers: 3}
    end

    test "fewer than three allowed cores runs a single partition" do
      assert CpuBudget.plan(2) == %{partitions: 1, schedulers: 2}
      assert CpuBudget.plan(1) == %{partitions: 1, schedulers: 2}
    end

    test "a forced partition count keeps the scheduler cap to the budget" do
      assert CpuBudget.plan(16, 8) == %{partitions: 8, schedulers: 2}
      assert CpuBudget.plan(16, 2) == %{partitions: 2, schedulers: 8}
    end
  end
end
