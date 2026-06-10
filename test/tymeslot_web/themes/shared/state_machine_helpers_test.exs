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

    test "5-state map includes awaiting_payment sharing the final step with confirmation" do
      states = StateMachineHelpers.states_for(%{custom_fields: [%{}]})

      assert states[:awaiting_payment]
      assert states[:awaiting_payment].step == states[:confirmation].step
      assert states[:awaiting_payment].prev == :booking
    end

    test "default 4-state map also includes awaiting_payment" do
      states = StateMachineHelpers.default_states()
      assert states[:awaiting_payment].step == states[:confirmation].step
      assert states[:awaiting_payment].prev == :booking
    end
  end

  describe "validate_state_transition/3 for the new questions state" do
    test "schedule → questions fails when no time selected" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{selected_date: nil, selected_time: nil, available_slots: [], __changed__: %{}}
      }

      assert {:error, _reason} =
               StateMachineHelpers.validate_state_transition(socket, :schedule, :questions)
    end

    test "questions → booking is always ok" do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

      assert :ok =
               StateMachineHelpers.validate_state_transition(socket, :questions, :booking)
    end
  end
end
