defmodule Tymeslot.Meetings.AttendeeNotifications.IcalMethodTest do
  use ExUnit.Case, async: true
  @moduletag :unit

  alias Tymeslot.Meetings.AttendeeNotifications.IcalMethod

  test "event_created → REQUEST, sequence 0" do
    assert IcalMethod.for(:event_created, current_sequence: 7) == {:request, 0}
  end

  test "event_updated → REQUEST, sequence + 1" do
    assert IcalMethod.for(:event_updated, current_sequence: 3) == {:request, 4}
  end

  test "attendees_added → REQUEST, sequence unchanged" do
    assert IcalMethod.for(:attendees_added, current_sequence: 3) == {:request, 3}
  end

  test "attendees_removed → CANCEL, sequence unchanged" do
    assert IcalMethod.for(:attendees_removed, current_sequence: 3) == {:cancel, 3}
  end

  test "event_deleted → CANCEL, sequence + 1" do
    assert IcalMethod.for(:event_deleted, current_sequence: 3) == {:cancel, 4}
  end
end
