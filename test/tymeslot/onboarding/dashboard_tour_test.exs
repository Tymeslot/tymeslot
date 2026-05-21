defmodule Tymeslot.Onboarding.DashboardTourTest do
  @moduledoc false
  use ExUnit.Case, async: true

  @moduletag :onboarding
  @moduletag :unit

  alias Tymeslot.Onboarding.DashboardTour

  describe "steps/0" do
    test "returns a non-empty list of step maps" do
      steps = DashboardTour.steps()
      assert is_list(steps)
      refute Enum.empty?(steps)
    end

    test "every step has the required keys" do
      for step <- DashboardTour.steps() do
        assert Map.has_key?(step, :id), "step missing :id — #{inspect(step)}"
        assert Map.has_key?(step, :anchor), "step missing :anchor — #{inspect(step)}"
        assert Map.has_key?(step, :placement), "step missing :placement — #{inspect(step)}"
        assert Map.has_key?(step, :title), "step missing :title — #{inspect(step)}"
        assert Map.has_key?(step, :body), "step missing :body — #{inspect(step)}"
      end
    end

    test "step ids are unique" do
      ids = Enum.map(DashboardTour.steps(), & &1.id)
      assert ids == Enum.uniq(ids)
    end

    test "non-nil anchors are unique" do
      anchors =
        DashboardTour.steps()
        |> Enum.map(& &1.anchor)
        |> Enum.reject(&is_nil/1)

      assert anchors == Enum.uniq(anchors)
    end

    test "placement is a known atom" do
      valid = [:top, :bottom, :left, :right, :bottom_end, :center]

      for step <- DashboardTour.steps() do
        assert step.placement in valid,
               "step #{inspect(step.id)} has invalid placement #{inspect(step.placement)}"
      end
    end

    test "centred steps have nil anchor and vice versa" do
      for step <- DashboardTour.steps() do
        if step.placement == :center do
          assert is_nil(step.anchor),
                 "centred step #{inspect(step.id)} must not have an anchor"
        else
          assert is_binary(step.anchor),
                 "non-centred step #{inspect(step.id)} must have a string anchor"
        end
      end
    end
  end

  describe "count/0" do
    test "matches steps/0 length" do
      assert DashboardTour.count() == length(DashboardTour.steps())
    end
  end

  describe "step_at/1" do
    test "returns the first step at index 0" do
      assert %{id: :welcome} = DashboardTour.step_at(0)
    end

    test "returns the last step at the final index" do
      last_index = DashboardTour.count() - 1
      last_step = DashboardTour.step_at(last_index)
      assert is_map(last_step)
      assert Map.has_key?(last_step, :id)
    end

    test "returns nil for an out-of-range index" do
      assert is_nil(DashboardTour.step_at(DashboardTour.count()))
      assert is_nil(DashboardTour.step_at(999))
    end
  end
end
