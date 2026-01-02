defmodule Tymeslot.DatabaseQueries.MeetingQueriesTest do
  @moduledoc false

  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.DatabaseQueries.MeetingQueries
  alias Tymeslot.Meetings.Scheduling

  # Helper functions to reduce duplication in test setup
  defp build_base_start_time(offset_days) do
    DateTime.utc_now()
    |> DateTime.add(offset_days, :day)
    |> DateTime.truncate(:second)
  end

  defp build_meeting_times(start_offset_days, duration_minutes) do
    start_time = build_base_start_time(start_offset_days)
    end_time = DateTime.add(start_time, duration_minutes, :minute)
    {start_time, end_time}
  end

  describe "reminder notification data access" do
    test "queries meetings in time window for reminders" do
      now = DateTime.utc_now()

      meeting_needing_reminder =
        insert(:meeting,
          start_time: DateTime.add(now, 30, :minute),
          status: "confirmed",
          reminder_email_sent: false
        )

      # Should not appear: too far in future
      insert(:meeting,
        start_time: DateTime.add(now, 2, :hour),
        status: "confirmed",
        reminder_email_sent: false
      )

      # Should not appear: reminder already sent
      insert(:meeting,
        start_time: DateTime.add(now, 30, :minute),
        status: "confirmed",
        reminder_email_sent: true
      )

      # Should not appear: not confirmed yet
      insert(:meeting,
        start_time: DateTime.add(now, 30, :minute),
        status: "pending",
        reminder_email_sent: false
      )

      one_hour_from_now = DateTime.add(now, 1, :hour)
      meetings = MeetingQueries.list_meetings_needing_reminders(now, one_hour_from_now)

      assert length(meetings) == 1
      assert hd(meetings).id == meeting_needing_reminder.id
    end
  end

  describe "time conflict detection (prevents double booking)" do
    test "prevents overlapping meetings" do
      {start_time, end_time} = build_meeting_times(1, 60)

      existing_meeting =
        insert(:meeting,
          start_time: start_time,
          end_time: end_time,
          status: "confirmed"
        )

      overlapping_start = DateTime.add(existing_meeting.start_time, 30, :minute)
      overlapping_end = DateTime.add(existing_meeting.end_time, 30, :minute)

      assert Scheduling.has_time_conflict?(overlapping_start, overlapping_end)
    end

    test "allows non-overlapping meetings" do
      {start_time, end_time} = build_meeting_times(1, 60)

      existing_meeting =
        insert(:meeting,
          start_time: start_time,
          end_time: end_time,
          status: "confirmed"
        )

      non_overlapping_start = DateTime.add(existing_meeting.end_time, 30, :minute)
      non_overlapping_end = DateTime.add(non_overlapping_start, 60, :minute)

      refute Scheduling.has_time_conflict?(non_overlapping_start, non_overlapping_end)
    end

    test "allows updating existing meeting without self-conflict" do
      {start_time, end_time} = build_meeting_times(1, 60)

      meeting =
        insert(:meeting,
          start_time: start_time,
          end_time: end_time,
          status: "confirmed"
        )

      refute Scheduling.has_time_conflict?(meeting.start_time, meeting.end_time, meeting.uid)
    end

    test "ignores cancelled meetings for conflicts" do
      {start_time, end_time} = build_meeting_times(1, 60)

      insert(:meeting,
        start_time: start_time,
        end_time: end_time,
        status: "cancelled"
      )

      same_time_start = build_base_start_time(1)
      same_time_end = DateTime.add(same_time_start, 60, :minute)

      refute Scheduling.has_time_conflict?(same_time_start, same_time_end)
    end
  end

  describe "safe meeting creation (prevents double booking)" do
    test "creates meeting when no conflicts exist" do
      {start_time, end_time} = build_meeting_times(1, 60)

      attrs = %{
        uid: "safe-meeting-123",
        title: "Safe Meeting",
        start_time: start_time,
        end_time: end_time,
        organizer_name: "Test Organizer",
        organizer_email: "organizer@example.com",
        attendee_name: "Test Attendee",
        attendee_email: "attendee@example.com"
      }

      {:ok, meeting} = Scheduling.create_meeting_with_conflict_check(attrs)
      assert meeting.uid == "safe-meeting-123"
    end

    test "prevents double booking with conflict error" do
      {existing_start, existing_end} = build_meeting_times(1, 60)

      insert(:meeting,
        start_time: existing_start,
        end_time: existing_end,
        status: "confirmed"
      )

      conflicting_attrs = %{
        uid: "conflicting-meeting-456",
        title: "Conflicting Meeting",
        start_time: DateTime.add(existing_start, 30, :minute),
        end_time: DateTime.add(existing_end, 30, :minute),
        organizer_name: "Test Organizer",
        organizer_email: "organizer@example.com",
        attendee_name: "Test Attendee",
        attendee_email: "attendee@example.com"
      }

      {:error, :time_conflict} =
        Scheduling.create_meeting_with_conflict_check(conflicting_attrs)
    end
  end

  describe "safe meeting updates (prevents conflicts)" do
    test "updates meeting when no conflicts exist" do
      meeting = insert(:meeting)
      {new_start, new_end} = build_meeting_times(2, 60)

      attrs = %{
        title: "Rescheduled Meeting",
        start_time: new_start,
        end_time: new_end
      }

      {:ok, updated} = Scheduling.update_meeting_with_conflict_check(meeting, attrs)
      assert updated.start_time == new_start
    end

    test "prevents reschedule conflicts" do
      meeting1 = insert(:meeting)

      {start_time2, end_time2} = build_meeting_times(2, 60)

      meeting2 =
        insert(:meeting,
          start_time: start_time2,
          end_time: end_time2,
          status: "confirmed"
        )

      conflicting_reschedule = %{
        start_time: DateTime.add(meeting2.start_time, 30, :minute),
        end_time: DateTime.add(meeting2.end_time, 30, :minute)
      }

      {:error, :time_conflict} =
        Scheduling.update_meeting_with_conflict_check(meeting1, conflicting_reschedule)
    end
  end

  describe "buffer time conflict detection" do
    test "respects buffer time between meetings" do
      user = insert(:user)
      _profile = insert(:profile, user: user, buffer_minutes: 30)

      {start_time1, end_time1} = build_meeting_times(1, 60)

      attrs1 = %{
        uid: "first-meeting",
        title: "First Meeting",
        start_time: start_time1,
        end_time: end_time1,
        organizer_name: "Test Organizer",
        organizer_email: "organizer@example.com",
        organizer_user_id: user.id,
        attendee_name: "Test Attendee",
        attendee_email: "attendee@example.com",
        status: "confirmed"
      }

      {:ok, _meeting1} = Scheduling.create_meeting_with_conflict_check(attrs1)

      # Should conflict: only 15 minutes buffer
      insufficient_buffer_start = DateTime.add(end_time1, 15, :minute)

      insufficient_buffer_attrs =
        Map.merge(attrs1, %{
          uid: "insufficient-buffer",
          start_time: insufficient_buffer_start,
          end_time: DateTime.add(insufficient_buffer_start, 60, :minute)
        })

      {:error, :time_conflict} =
        Scheduling.create_meeting_with_conflict_check(insufficient_buffer_attrs)

      # Should succeed: 45 minutes buffer (exceeds required 30)
      sufficient_buffer_start = DateTime.add(end_time1, 45, :minute)

      sufficient_buffer_attrs =
        Map.merge(attrs1, %{
          uid: "sufficient-buffer",
          start_time: sufficient_buffer_start,
          end_time: DateTime.add(sufficient_buffer_start, 60, :minute)
        })

      {:ok, meeting3} = Scheduling.create_meeting_with_conflict_check(sufficient_buffer_attrs)
      assert meeting3.uid == "sufficient-buffer"
    end
  end
end
