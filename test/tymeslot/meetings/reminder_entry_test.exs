defmodule Tymeslot.Meetings.ReminderEntryTest do
  use ExUnit.Case, async: true

  @moduletag :meetings
  @moduletag :notifications

  alias Tymeslot.Meetings.ReminderEntry

  describe "status/3" do
    test "no entry for the reminder means it has gone to neither recipient" do
      assert ReminderEntry.status([], 1, "hours") == %{organizer: false, attendee: false}
      assert ReminderEntry.status(nil, 1, "hours") == %{organizer: false, attendee: false}

      assert ReminderEntry.status([%{"value" => 30, "unit" => "minutes"}], 1, "hours") ==
               %{organizer: false, attendee: false}
    end

    test "reads each recipient's flag, with string keys as stored" do
      entries = [
        %{"value" => 1, "unit" => "hours", "organizer_sent" => true, "attendee_sent" => false}
      ]

      assert ReminderEntry.status(entries, 1, "hours") == %{organizer: true, attendee: false}
    end

    test "reads atom keys too, as a struct built in memory carries them" do
      entries = [%{value: 1, unit: "hours", organizer_sent: false, attendee_sent: true}]

      assert ReminderEntry.status(entries, 1, "hours") == %{organizer: false, attendee: true}
    end

    # An entry written before per-recipient tracking exists because the
    # reminder fired; it must never trigger a fresh send.
    test "an entry with no per-recipient flags reads as sent to both" do
      assert ReminderEntry.status([%{"value" => 1, "unit" => "hours"}], 1, "hours") ==
               %{organizer: true, attendee: true}
    end

    test "a flag that is not a boolean reads as sent, like a missing one" do
      entries = [%{"value" => 1, "unit" => "hours", "organizer_sent" => nil}]

      assert %{organizer: true} = ReminderEntry.status(entries, 1, "hours")
    end
  end

  test "an entry of an unknown shape is for no reminder" do
    refute ReminderEntry.for_reminder?(%{"label" => "1 hour"}, 1, "hours")
    refute ReminderEntry.for_reminder?(nil, 1, "hours")
  end
end
