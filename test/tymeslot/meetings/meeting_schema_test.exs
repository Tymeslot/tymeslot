defmodule Tymeslot.Meetings.MeetingSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :schema

  alias Ecto.{Changeset, UUID}
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting

  @valid_base_attrs %{
    uid: "test-uid-123",
    title: "Test Meeting",
    start_time: ~U[2024-01-01 10:00:00Z],
    end_time: ~U[2024-01-01 11:00:00Z],
    organizer_name: "Test Organizer",
    organizer_email: "organizer@test.com",
    attendee_name: "Test Attendee",
    attendee_email: "attendee@test.com"
  }

  describe "custom_fields_snapshot and custom_field_answers" do
    test "custom_fields_snapshot defaults to empty list when omitted from the changeset" do
      cs = Meeting.changeset(%Meeting{}, @valid_base_attrs)

      assert cs.valid?
      assert Changeset.get_field(cs, :custom_fields_snapshot) == []
    end

    test "custom_field_answers defaults to empty map when omitted from the changeset" do
      cs = Meeting.changeset(%Meeting{}, @valid_base_attrs)

      assert cs.valid?
      assert Changeset.get_field(cs, :custom_field_answers) == %{}
    end

    test "changeset accepts a snapshot and answers map" do
      field_id = UUID.generate()
      snap = [%{"id" => field_id, "type" => "short_text", "label" => "Company"}]
      ans = %{field_id => "Acme"}

      attrs =
        Map.merge(@valid_base_attrs, %{
          custom_fields_snapshot: snap,
          custom_field_answers: ans
        })

      cs = Meeting.changeset(%Meeting{}, attrs)

      assert cs.valid?
      assert Changeset.get_field(cs, :custom_fields_snapshot) == snap
      assert Changeset.get_field(cs, :custom_field_answers) == ans
    end
  end

  describe "provider_event_id" do
    test "accepts an id at Google's 1024-character maximum" do
      attrs = Map.put(@valid_base_attrs, :provider_event_id, String.duplicate("a", 1024))

      cs = Meeting.changeset(%Meeting{}, attrs)

      assert cs.valid?
    end

    test "rejects an id longer than 1024 characters with a changeset error" do
      attrs = Map.put(@valid_base_attrs, :provider_event_id, String.duplicate("a", 1025))

      cs = Meeting.changeset(%Meeting{}, attrs)

      refute cs.valid?
      assert %{provider_event_id: [_message]} = errors_on(cs)
    end
  end

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

  describe "status enum" do
    test "accepts awaiting_payment" do
      changeset = Meeting.changeset(%Meeting{}, %{status: "awaiting_payment"})

      refute Map.has_key?(errors_on(changeset), :status)
    end

    test "accepts expired" do
      changeset = Meeting.changeset(%Meeting{}, %{status: "expired"})

      refute Map.has_key?(errors_on(changeset), :status)
    end

    test "rejects unknown status" do
      changeset = Meeting.changeset(%Meeting{}, %{status: "not_a_real_status"})

      assert "is invalid" in errors_on(changeset).status
    end
  end
end
