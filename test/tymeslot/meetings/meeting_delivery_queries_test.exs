defmodule Tymeslot.Meetings.MeetingDeliveryQueriesTest do
  @moduledoc false

  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.Meetings.MeetingDeliveryQueries

  describe "upsert_reminder_sent/2" do
    test "appends a new per-recipient entry for a reminder config not seen before" do
      meeting = insert(:meeting, reminders_sent: [])

      {:ok, updated} =
        MeetingDeliveryQueries.upsert_reminder_sent(meeting, %{
          value: 30,
          unit: "minutes",
          organizer_sent: true,
          attendee_sent: false
        })

      assert updated.reminders_sent == [
               %{
                 "value" => 30,
                 "unit" => "minutes",
                 "organizer_sent" => true,
                 "attendee_sent" => false
               }
             ]

      assert updated.reminder_email_sent == true
    end

    test "OR-merges flags into an existing entry instead of duplicating it" do
      meeting = insert(:meeting, reminders_sent: [])

      {:ok, updated} =
        MeetingDeliveryQueries.upsert_reminder_sent(meeting, %{
          value: 30,
          unit: "minutes",
          organizer_sent: true,
          attendee_sent: false
        })

      {:ok, updated2} =
        MeetingDeliveryQueries.upsert_reminder_sent(updated, %{
          value: 30,
          unit: "minutes",
          organizer_sent: false,
          attendee_sent: true
        })

      assert updated2.reminders_sent == [
               %{
                 "value" => 30,
                 "unit" => "minutes",
                 "organizer_sent" => true,
                 "attendee_sent" => true
               }
             ]

      # A second, distinct reminder config gets its own entry.
      {:ok, updated3} =
        MeetingDeliveryQueries.upsert_reminder_sent(updated2, %{
          value: 1,
          unit: "hours",
          organizer_sent: true,
          attendee_sent: true
        })

      assert length(updated3.reminders_sent) == 2

      assert %{
               "value" => 1,
               "unit" => "hours",
               "organizer_sent" => true,
               "attendee_sent" => true
             } in updated3.reminders_sent
    end

    test "handles nil reminders_sent" do
      meeting = insert(:meeting, reminders_sent: nil)

      {:ok, updated} =
        MeetingDeliveryQueries.upsert_reminder_sent(meeting, %{
          value: 30,
          unit: "minutes",
          organizer_sent: true,
          attendee_sent: true
        })

      assert updated.reminders_sent == [
               %{
                 "value" => 30,
                 "unit" => "minutes",
                 "organizer_sent" => true,
                 "attendee_sent" => true
               }
             ]
    end

    test "treats a pre-existing entry with no per-recipient flags as already fully sent" do
      meeting =
        insert(:meeting, reminders_sent: [%{"value" => 30, "unit" => "minutes"}])

      {:ok, updated} =
        MeetingDeliveryQueries.upsert_reminder_sent(meeting, %{
          value: 30,
          unit: "minutes",
          organizer_sent: false,
          attendee_sent: true
        })

      assert updated.reminders_sent == [
               %{
                 "value" => 30,
                 "unit" => "minutes",
                 "organizer_sent" => true,
                 "attendee_sent" => true
               }
             ]
    end
  end
end
