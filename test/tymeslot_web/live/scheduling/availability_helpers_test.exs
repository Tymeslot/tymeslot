defmodule TymeslotWeb.Live.Scheduling.AvailabilityHelpersTest do
  use Tymeslot.DataCase, async: true

  alias TymeslotWeb.Live.Scheduling.AvailabilityHelpers

  @moduletag :availability
  @moduletag :unit

  describe "schedule_config/3" do
    test "carries the meeting type's slot interval" do
      config = AvailabilityHelpers.schedule_config(nil, %{slot_interval_minutes: 5}, nil)

      assert config.slot_interval_minutes == 5
    end

    test "carries nil when the meeting type has no interval" do
      config = AvailabilityHelpers.schedule_config(nil, %{slot_interval_minutes: nil}, nil)

      assert config.slot_interval_minutes == nil
    end

    test "carries nil when there is no meeting type at all" do
      config = AvailabilityHelpers.schedule_config(nil, nil, nil)

      assert config.slot_interval_minutes == nil
    end
  end
end
