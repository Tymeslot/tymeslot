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

  describe "with_status/2" do
    @now ~U[2026-06-01 12:00:00Z]

    # A confirmed booking a day out: every reminder under a day is still to come.
    defp booking(attrs) do
      Map.merge(
        %{
          status: "confirmed",
          start_time: DateTime.add(@now, 1, :day),
          reschedule_requested_at: nil,
          reminders: [%{"value" => 20, "unit" => "minutes"}],
          reminders_sent: nil
        },
        Map.new(attrs)
      )
    end

    test "marks a reminder recorded as sent, and leaves the rest to come" do
      meeting =
        booking(
          reminders: [%{"value" => 20, "unit" => "minutes"}, %{"value" => 5, "unit" => "minutes"}],
          reminders_sent: [
            %{
              "value" => 20,
              "unit" => "minutes",
              "organizer_sent" => true,
              "attendee_sent" => true
            }
          ]
        )

      assert [%{value: 20, status: :sent}, %{value: 5, status: :upcoming}] =
               ReminderSchedule.with_status(meeting, @now)
    end

    test "one recipient reached is enough to count as sent" do
      meeting =
        booking(
          reminders_sent: [
            %{
              "value" => 20,
              "unit" => "minutes",
              "organizer_sent" => false,
              "attendee_sent" => true
            }
          ]
        )

      assert [%{status: :sent}] = ReminderSchedule.with_status(meeting, @now)
    end

    test "an entry from before the per-recipient flags counts as sent" do
      # The entry exists because the reminder fired; guessing it did not would
      # show a reminder as still coming long after it went out.
      meeting = booking(reminders_sent: [%{"value" => 20, "unit" => "minutes"}])

      assert [%{status: :sent}] = ReminderSchedule.with_status(meeting, @now)
    end

    test "an entry for a different lead time does not mark this one" do
      meeting =
        booking(
          reminders_sent: [
            %{"value" => 20, "unit" => "hours", "organizer_sent" => true, "attendee_sent" => true}
          ]
        )

      assert [%{status: :upcoming}] = ReminderSchedule.with_status(meeting, @now)
    end

    test "a reminder whose moment passed without it going out reads as not sent" do
      # Booked an hour ahead: the two-hour reminder was never scheduled, while
      # the 20-minute one still is.
      meeting =
        booking(
          start_time: DateTime.add(@now, 1, :hour),
          reminders: [%{"value" => 2, "unit" => "hours"}, %{"value" => 20, "unit" => "minutes"}]
        )

      assert [%{value: 2, status: :not_sent}, %{value: 20, status: :upcoming}] =
               ReminderSchedule.with_status(meeting, @now)
    end

    test "a past meeting's unsent reminder reads as not sent, not as still to come" do
      meeting = booking(start_time: DateTime.add(@now, -1, :day))

      assert [%{status: :not_sent}] = ReminderSchedule.with_status(meeting, @now)
    end

    test "a held booking says what its reminders are waiting on" do
      assert [%{status: :after_approval}] =
               ReminderSchedule.with_status(booking(status: "awaiting_approval"), @now)

      assert [%{status: :after_payment}] =
               ReminderSchedule.with_status(booking(status: "awaiting_payment"), @now)

      assert [%{status: :after_rescheduling}] =
               ReminderSchedule.with_status(
                 booking(reschedule_requested_at: DateTime.add(@now, -1, :hour)),
                 @now
               )
    end

    test "a released booking has no reminders left" do
      assert ReminderSchedule.with_status(booking(status: "cancelled"), @now) == []
      assert ReminderSchedule.with_status(booking(status: "expired"), @now) == []
    end
  end
end
