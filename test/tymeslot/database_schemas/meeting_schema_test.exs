defmodule Tymeslot.DatabaseSchemas.MeetingSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :schema

  alias Tymeslot.DatabaseSchemas.MeetingSchema, as: Meeting

  describe "business logic" do
    test "prevents meetings with end time before start time" do
      attrs = %{
        uid: "test-uid-123",
        title: "Invalid Meeting",
        start_time: ~U[2024-01-01 11:00:00Z],
        end_time: ~U[2024-01-01 10:00:00Z],
        organizer_name: "Test Organizer",
        organizer_email: "organizer@test.com",
        attendee_name: "Test Attendee",
        attendee_email: "attendee@test.com"
      }

      changeset = Meeting.changeset(%Meeting{}, attrs)
      refute changeset.valid?
      assert "must be after start time" in errors_on(changeset).end_time
    end

    test "calculates duration from start and end times" do
      attrs = %{
        uid: "test-uid-123",
        title: "Test Meeting",
        start_time: ~U[2024-01-01 10:00:00Z],
        end_time: ~U[2024-01-01 11:30:00Z],
        organizer_name: "Test Organizer",
        organizer_email: "organizer@test.com",
        attendee_name: "Test Attendee",
        attendee_email: "attendee@test.com"
      }

      changeset = Meeting.changeset(%Meeting{}, attrs)
      assert changeset.changes.duration == 90
    end

    test "determines if meeting is currently happening" do
      now = DateTime.utc_now()
      start_time = DateTime.add(now, -30, :minute)
      end_time = DateTime.add(now, 30, :minute)

      meeting = %Meeting{start_time: start_time, end_time: end_time}
      assert Meeting.current?(meeting)
    end

    test "determines if meeting is in the future" do
      future_time = DateTime.add(DateTime.utc_now(), 1, :hour)
      meeting = %Meeting{start_time: future_time}
      assert Meeting.future?(meeting)
    end
  end
end
