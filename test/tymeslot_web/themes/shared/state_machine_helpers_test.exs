defmodule TymeslotWeb.Themes.Shared.StateMachineHelpersTest do
  use Tymeslot.DataCase, async: true

  @moduletag :custom_fields

  alias TymeslotWeb.Themes.Shared.StateMachineHelpers

  describe "states_for/1" do
    test "returns the 4-state map when no custom fields" do
      assert StateMachineHelpers.states_for(%{custom_fields: []}) ==
               StateMachineHelpers.default_states()
    end

    test "returns the 4-state map when custom_fields is absent" do
      assert StateMachineHelpers.states_for(%{}) ==
               StateMachineHelpers.default_states()
    end

    test "inserts the questions state when fields are present" do
      states = StateMachineHelpers.states_for(%{custom_fields: [%{}]})
      assert states[:questions]
      assert states[:schedule].next == :questions
      assert states[:booking].prev == :questions
    end

    test "5-state map advances numeric step counts correctly" do
      states = StateMachineHelpers.states_for(%{custom_fields: [%{}]})
      assert states[:overview].step == 1
      assert states[:schedule].step == 2
      assert states[:questions].step == 3
      assert states[:booking].step == 4
      assert states[:confirmation].step == 5
    end
  end
end
