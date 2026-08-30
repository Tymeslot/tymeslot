defmodule Tymeslot.Notifications.EventTypesTest do
  use ExUnit.Case, async: true

  @moduletag :notifications

  alias Tymeslot.Notifications.EventTypes

  describe "to_event_type/1" do
    test "maps the three known event atoms to their wire names" do
      assert EventTypes.to_event_type(:meeting_created) == "meeting.created"
      assert EventTypes.to_event_type(:meeting_cancelled) == "meeting.cancelled"
      assert EventTypes.to_event_type(:meeting_rescheduled) == "meeting.rescheduled"
    end

    test "raises on an atom with no known wire name" do
      assert_raise ArgumentError, ~r/unknown event type/, fn ->
        EventTypes.to_event_type(:something_new)
      end
    end
  end

  describe "all/0" do
    test "returns every wire name to_event_type/1 can produce" do
      assert Enum.sort(EventTypes.all()) ==
               Enum.sort(["meeting.created", "meeting.cancelled", "meeting.rescheduled"])
    end
  end
end
