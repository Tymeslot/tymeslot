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

  describe "calendar_uid" do
    # The uid is the booking's cancel/reschedule capability; the calendar uid
    # is what external calendars see, so it must not be derivable from it.
    test "a new meeting gets a calendar uid of its own" do
      cs = Meeting.changeset(%Meeting{}, @valid_base_attrs)

      assert cs.valid?
      calendar_uid = Changeset.get_change(cs, :calendar_uid)
      assert {:ok, _uuid} = UUID.cast(calendar_uid)
      refute calendar_uid == @valid_base_attrs.uid
    end

    test "two new meetings never share one" do
      first = Meeting.changeset(%Meeting{}, @valid_base_attrs)
      second = Meeting.changeset(%Meeting{}, @valid_base_attrs)

      refute Changeset.get_change(first, :calendar_uid) ==
               Changeset.get_change(second, :calendar_uid)
    end

    # Rotating it would orphan the event already written under it; a
    # reschedule has to update that event, not lose it.
    test "an existing meeting keeps its calendar uid through an update" do
      meeting = insert(:meeting)

      {:ok, updated} =
        meeting
        |> Meeting.changeset(%{
          start_time: DateTime.add(meeting.start_time, 3600, :second),
          end_time: DateTime.add(meeting.end_time, 3600, :second)
        })
        |> Repo.update()

      assert updated.calendar_uid == meeting.calendar_uid
    end

    test "is unique across meetings" do
      existing = insert(:meeting)

      assert {:error, changeset} =
               %Meeting{}
               |> Meeting.changeset(
                 Map.put(@valid_base_attrs, :calendar_uid, existing.calendar_uid)
               )
               |> Repo.insert()

      assert {"has already been taken", _meta} = changeset.errors[:calendar_uid]
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
