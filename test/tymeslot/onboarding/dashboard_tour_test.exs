defmodule Tymeslot.Onboarding.DashboardTourTest do
  @moduledoc false
  use ExUnit.Case, async: true

  @moduletag :onboarding
  @moduletag :unit

  alias Tymeslot.Onboarding.DashboardTour

  # Every condition satisfied — the full catalogue.
  defp all_steps, do: DashboardTour.steps(%{checklist_visible?: true})

  describe "steps/1" do
    test "returns a non-empty list of step maps" do
      steps = all_steps()

      assert length(steps) == 5
      assert %{id: :welcome} = List.first(steps)
      assert %{id: :done} = List.last(steps)
    end

    test "every step has the required keys" do
      for step <- all_steps() do
        assert Map.has_key?(step, :id), "step missing :id — #{inspect(step)}"
        assert Map.has_key?(step, :anchor), "step missing :anchor — #{inspect(step)}"
        assert Map.has_key?(step, :placement), "step missing :placement — #{inspect(step)}"
        assert Map.has_key?(step, :title), "step missing :title — #{inspect(step)}"
        assert Map.has_key?(step, :body), "step missing :body — #{inspect(step)}"
        assert Map.has_key?(step, :requires), "step missing :requires — #{inspect(step)}"
      end
    end

    test "step ids are unique" do
      ids = Enum.map(all_steps(), & &1.id)
      assert ids == Enum.uniq(ids)
    end

    test "non-nil anchors are unique" do
      anchors =
        all_steps()
        |> Enum.map(& &1.anchor)
        |> Enum.reject(&is_nil/1)

      assert anchors == Enum.uniq(anchors)
    end

    test "placement is a known atom" do
      valid = [:top, :bottom, :left, :right, :bottom_end, :center]

      for step <- all_steps() do
        assert step.placement in valid,
               "step #{inspect(step.id)} has invalid placement #{inspect(step.placement)}"
      end
    end

    test "centred steps have nil anchor and vice versa" do
      for step <- all_steps() do
        if step.placement == :center do
          assert is_nil(step.anchor),
                 "centred step #{inspect(step.id)} must not have an anchor"
        else
          assert is_binary(step.anchor),
                 "non-centred step #{inspect(step.id)} must have a string anchor"
        end
      end
    end

    test "an unmet condition drops the step that declares it" do
      steps = DashboardTour.steps(%{checklist_visible?: false})

      refute Enum.any?(steps, &(&1.id == :quick_actions))
      assert length(steps) == length(all_steps()) - 1
    end

    test "an absent condition key is treated as unmet" do
      assert DashboardTour.steps(%{}) == DashboardTour.steps(%{checklist_visible?: false})
    end

    test "unconditional steps survive an empty context" do
      ids = Enum.map(DashboardTour.steps(%{}), & &1.id)

      assert :welcome in ids
      assert :sidebar_nav in ids
      assert :user_menu in ids
      assert :done in ids
    end
  end
end
