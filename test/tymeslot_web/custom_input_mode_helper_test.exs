defmodule TymeslotWeb.CustomInputModeHelperTest do
  @moduledoc """
  Checks the preset tables the availability and meeting type forms offer
  against the defaults new records are created with.
  """

  use ExUnit.Case, async: true
  @moduletag :availability

  alias Tymeslot.Availability.AvailabilityScheduleSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.CustomInputModeHelper

  describe "presets against the defaults a new schedule is created with" do
    # A default the tags do not offer opens the setting in custom-input mode for
    # every new user, with no tag highlighted. That is how the card's
    # minimum-notice list was found to be missing 3, the schema's own default.

    # The custom-input fields whose default lives on the availability schedule.
    # `:slot_interval_minutes` is deliberately absent: it sits on the meeting
    # type, and its default is NULL, which the form offers as "Same as meeting
    # length" rather than as a preset integer.
    @schedule_policy_fields [
      :buffer_before_minutes,
      :buffer_after_minutes,
      :advance_booking_days,
      :min_advance_hours
    ]

    test "every custom-input field is accounted for by one of the two defaults rules" do
      # Without this, adding a field to the preset table would silently drop out
      # of the coverage below instead of failing until someone decides which
      # rule it falls under.
      assert Enum.sort(CustomInputModeHelper.fields()) ==
               Enum.sort([:slot_interval_minutes | @schedule_policy_fields])
    end

    test "every scheduling policy default is offered as a preset" do
      schedule = %AvailabilityScheduleSchema{}
      defaults = Enum.map(@schedule_policy_fields, &{&1, Map.fetch!(schedule, &1)})

      # Anchor: no fields would make the rejection below vacuous.
      refute Enum.empty?(defaults)

      assert Enum.reject(defaults, fn {field, value} ->
               CustomInputModeHelper.preset_value?(field, value)
             end) == []
    end

    test "the interval's NULL default is not a preset, and needs no tag" do
      assert %MeetingTypeSchema{}.slot_interval_minutes == nil
      refute CustomInputModeHelper.preset_value?(:slot_interval_minutes, nil)
    end
  end

  describe "toggle_custom_mode/4 rejecting a spoofed preset click" do
    # The `_preset` marker is client-supplied. A value outside the preset list
    # must not be taken as a preset click, or a forged request could switch the
    # card out of custom-input mode for a value it never offered.

    defp socket_with_custom_mode(field, enabled) do
      mode = Map.put(CustomInputModeHelper.default_custom_mode(), field, enabled)
      %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, custom_input_mode: mode}}
    end

    test "a preset marker with a non-preset value leaves custom mode on" do
      socket = socket_with_custom_mode(:buffer_before_minutes, true)
      refute CustomInputModeHelper.preset_value?(:buffer_before_minutes, 20)

      result =
        CustomInputModeHelper.toggle_custom_mode(
          socket,
          :buffer_before_minutes,
          %{"_preset" => "true", "buffer_before_minutes" => "20"},
          20
        )

      assert result.assigns.custom_input_mode.buffer_before_minutes == true
    end

    test "a preset marker with a real preset value turns custom mode off" do
      socket = socket_with_custom_mode(:buffer_before_minutes, true)

      result =
        CustomInputModeHelper.toggle_custom_mode(
          socket,
          :buffer_before_minutes,
          %{"_preset" => "true", "buffer_before_minutes" => "15"},
          15
        )

      assert result.assigns.custom_input_mode.buffer_before_minutes == false
    end
  end

  describe "presets against the range the schema validates against" do
    # The presets are literals here while the changeset that validates what the
    # form submits reads its bounds from `Constraints`. A preset outside the
    # range would render as a one-click choice and then be rejected on submit.

    test "every preset of every scheduling policy field passes the policy changeset" do
      fields = [
        :buffer_before_minutes,
        :buffer_after_minutes,
        :advance_booking_days,
        :min_advance_hours
      ]

      rejected =
        for field <- fields,
            value <- CustomInputModeHelper.presets(field),
            not AvailabilityScheduleSchema.policy_changeset(
              %AvailabilityScheduleSchema{},
              %{field => value}
            ).valid?,
            do: {field, value}

      # Anchor: an empty preset table would make the rejection vacuous.
      assert Enum.all?(fields, &(CustomInputModeHelper.presets(&1) != []))
      assert rejected == []
    end

    test "every slot interval preset is inside the interval range" do
      range = Constraints.slot_interval_minutes_range()
      presets = CustomInputModeHelper.presets(:slot_interval_minutes)

      refute Enum.empty?(presets)
      assert Enum.reject(presets, &(&1 in range)) == []
    end
  end
end
