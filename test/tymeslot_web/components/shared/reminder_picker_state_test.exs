defmodule TymeslotWeb.Components.Shared.ReminderPickerStateTest do
  @moduledoc """
  Covers `ReminderPickerState.commit_pending/2`: what the custom row still
  holds is added when its owner moves on, rather than dropped.
  """

  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :meeting_types

  alias Tymeslot.MeetingTypes.ReminderValidation
  alias TymeslotWeb.Components.Shared.ReminderPickerState

  defp typed(value, unit \\ "hours") do
    %{
      ReminderPickerState.new()
      | show_custom_reminder: true,
        new_reminder_value: value,
        new_reminder_unit: unit
    }
  end

  describe "commit_pending/2" do
    test "adds a typed value and closes the row" do
      assert {:ok, state} = ReminderPickerState.commit_pending(typed("2"))
      assert state.reminders == [%{value: 2, unit: "hours"}]
      refute state.show_custom_reminder
      assert state.new_reminder_value == ""
    end

    test "prefers the values the row posts over what was last recorded" do
      params = %{"reminder" => %{"value" => "3", "unit" => "days"}}
      assert {:ok, state} = ReminderPickerState.commit_pending(typed(""), params)
      assert state.reminders == [%{value: 3, unit: "days"}]
    end

    test "rejects an invalid value with the picker's own message" do
      assert {:noop, state} = ReminderPickerState.commit_pending(typed("0"))
      assert state.reminders == []
      assert state.reminder_error =~ "positive number"
    end

    test "does nothing for a closed or empty row" do
      closed = %{typed("2") | show_custom_reminder: false}
      assert {:noop, ^closed} = ReminderPickerState.commit_pending(closed)

      empty = typed("  ")
      assert {:noop, ^empty} = ReminderPickerState.commit_pending(empty)
    end

    test "does nothing once the limit has hidden the row" do
      full =
        for n <- 1..ReminderValidation.max_reminders()//1, do: %{value: n * 5, unit: "minutes"}

      state = %{typed("2") | reminders: full}
      refute ReminderPickerState.pending?(state)
      assert {:noop, ^state} = ReminderPickerState.commit_pending(state)
    end
  end
end
