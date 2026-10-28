defmodule TymeslotWeb.Themes.Shared.ChosenLengthTest do
  use ExUnit.Case, async: true

  @moduletag :scheduling
  @moduletag :themes

  alias TymeslotWeb.Themes.Shared.ChosenLength

  @several %{duration_minutes: 30, extra_lengths_minutes: [60, 15]}

  describe "meeting_type/1" do
    test "takes the type at the length chosen, which the calendar grids read" do
      assigns = %{meeting_type: @several, chosen_length_minutes: 60}

      assert ChosenLength.meeting_type(assigns).duration_minutes == 60
    end

    test "a reschedule's booked length wins over a choice" do
      assigns = %{
        meeting_type: @several,
        chosen_length_minutes: 15,
        reschedule_context: %{meeting: %{duration: 60}}
      }

      assert ChosenLength.meeting_type(assigns).duration_minutes == 60
    end

    test "a length the type does not offer leaves its primary one" do
      assigns = %{meeting_type: @several, chosen_length_minutes: 45}

      assert ChosenLength.meeting_type(assigns).duration_minutes == 30
    end

    test "without a type there is none" do
      assert ChosenLength.meeting_type(%{chosen_length_minutes: 60}) == nil
    end
  end
end
