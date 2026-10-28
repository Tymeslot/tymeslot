defmodule Tymeslot.Precommit.CpuBudgetTest do
  use ExUnit.Case, async: true

  @moduletag :dev_support

  alias Tymeslot.Precommit.CpuBudget

  describe "plan/2" do
    test "a 16-core allowance gets six partitions of two schedulers" do
      assert CpuBudget.plan(16) == %{partitions: 6, schedulers: 2}
    end

    test "never plans more than six partitions, however many cores are allowed" do
      assert CpuBudget.plan(64) == %{partitions: 6, schedulers: 10}
    end

    test "a smaller allowance (a CPU quota) gets one partition per core" do
      assert CpuBudget.plan(4) == %{partitions: 4, schedulers: 1}
      assert CpuBudget.plan(2) == %{partitions: 2, schedulers: 1}
    end

    test "a single allowed core runs a single partition" do
      assert CpuBudget.plan(1) == %{partitions: 1, schedulers: 1}
    end

    test "a forced partition count keeps the scheduler cap to the budget" do
      assert CpuBudget.plan(16, 8) == %{partitions: 8, schedulers: 2}
      assert CpuBudget.plan(4, 8) == %{partitions: 8, schedulers: 1}
      assert CpuBudget.plan(16, 2) == %{partitions: 2, schedulers: 8}
    end
  end

  describe "planner/1" do
    test "never plans more partitions than a selection has files" do
      plan = CpuBudget.planner(%{scope: :selection, files: ["a_test.exs"]}).()

      # A partitioned run of this suite gets no plan of its own.
      case CpuBudget.suite_plan() do
        nil -> assert plan == nil
        _plan -> assert %{partitions: 1} = plan
      end
    end

    test "plans a full or upstream suite like the whole one" do
      assert CpuBudget.planner(nil).() == CpuBudget.suite_plan()
      assert CpuBudget.planner(:upstream).() == CpuBudget.suite_plan()
    end
  end
end
