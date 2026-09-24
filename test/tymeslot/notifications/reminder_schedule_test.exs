defmodule Tymeslot.Notifications.ReminderScheduleTest do
  @moduledoc """
  Covers what a meeting is read to remind with: its own list, the legacy shapes
  older rows carry, and which of those reminders have already gone out.
  """

  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :notifications

  alias Tymeslot.Notifications.ReminderSchedule

  describe "configured/1" do
    test "returns the meeting's own reminders, in order" do
      meeting = %{
        reminders: [%{"value" => 20, "unit" => "minutes"}, %{"value" => 1, "unit" => "days"}]
      }

      assert ReminderSchedule.configured(meeting) == [
               %{value: 20, unit: "minutes"},
               %{value: 1, unit: "days"}
             ]
    end

    test "an empty list is an answer: no reminders" do
      assert ReminderSchedule.configured(%{reminders: []}) == []
    end

    test "a nil column is a row from before it existed, and falls back" do
      # Not the same as an empty list: `Orchestrator` schedules this fallback,
      # so showing "none" for such a booking would contradict the email it gets.
      meeting = %{reminders: nil, reminder_time: "2 hours", default_reminder_time: nil}

      assert ReminderSchedule.configured(meeting) == [%{value: 2, unit: "hours"}]
    end

    test "the fallback ends at 30 minutes when the legacy fields are empty too" do
      meeting = %{reminders: nil, reminder_time: nil, default_reminder_time: nil}

      assert ReminderSchedule.configured(meeting) == [%{value: 30, unit: "minutes"}]
    end
  end

  describe "with_status/1" do
    test "marks a reminder recorded as sent" do
      meeting = %{
        reminders: [%{"value" => 20, "unit" => "minutes"}, %{"value" => 5, "unit" => "minutes"}],
        reminders_sent: [
          %{"value" => 20, "unit" => "minutes", "organizer_sent" => true, "attendee_sent" => true}
        ]
      }

      assert [%{value: 20, sent?: true}, %{value: 5, sent?: false}] =
               ReminderSchedule.with_status(meeting)
    end

    test "one recipient reached is enough to count as sent" do
      meeting = %{
        reminders: [%{"value" => 20, "unit" => "minutes"}],
        reminders_sent: [
          %{
            "value" => 20,
            "unit" => "minutes",
            "organizer_sent" => false,
            "attendee_sent" => true
          }
        ]
      }

      assert [%{sent?: true}] = ReminderSchedule.with_status(meeting)
    end

    test "an entry from before the per-recipient flags counts as sent" do
      # The entry exists because the reminder fired; guessing it did not would
      # show a reminder as still coming long after it went out.
      meeting = %{
        reminders: [%{"value" => 20, "unit" => "minutes"}],
        reminders_sent: [%{"value" => 20, "unit" => "minutes"}]
      }

      assert [%{sent?: true}] = ReminderSchedule.with_status(meeting)
    end

    test "an entry for a different lead time does not mark this one" do
      meeting = %{
        reminders: [%{"value" => 20, "unit" => "minutes"}],
        reminders_sent: [
          %{"value" => 20, "unit" => "hours", "organizer_sent" => true, "attendee_sent" => true}
        ]
      }

      assert [%{sent?: false}] = ReminderSchedule.with_status(meeting)
    end

    test "nothing sent yet reads as nothing sent" do
      meeting = %{reminders: [%{"value" => 20, "unit" => "minutes"}], reminders_sent: nil}

      assert [%{sent?: false}] = ReminderSchedule.with_status(meeting)
    end
  end
end
