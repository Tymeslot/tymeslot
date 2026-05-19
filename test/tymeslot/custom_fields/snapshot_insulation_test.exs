defmodule Tymeslot.CustomFields.SnapshotInsulationTest do
  use Tymeslot.DataCase, async: true

  @moduletag :custom_fields

  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo

  describe "booking snapshot is insulated from meeting type edits" do
    setup do
      user = insert(:user)
      field_id = UUID.generate()

      meeting_type = insert(:meeting_type, user: user)

      {:ok, meeting_type} =
        MeetingTypes.update_meeting_type(meeting_type, %{
          "custom_fields" => [
            %{"id" => field_id, "type" => "short_text", "label" => "Company"}
          ]
        })

      meeting =
        insert(:meeting,
          attendee_email: "jane@example.com",
          custom_fields_snapshot: [
            %{"id" => field_id, "type" => "short_text", "label" => "Company"}
          ],
          custom_field_answers: %{field_id => "Acme"}
        )

      %{user: user, meeting_type: meeting_type, meeting: meeting, field_id: field_id}
    end

    test "renaming a field does not change past bookings",
         %{meeting_type: mt, meeting: meeting, field_id: field_id} do
      {:ok, _mt} =
        MeetingTypes.update_meeting_type(mt, %{
          "custom_fields" => [
            %{"id" => field_id, "type" => "short_text", "label" => "Organisation"}
          ]
        })

      reloaded = Repo.get!(MeetingSchema, meeting.id)
      assert hd(reloaded.custom_fields_snapshot)["label"] == "Company"
      assert reloaded.custom_field_answers[field_id] == "Acme"
    end

    test "deleting a field does not delete past answers",
         %{meeting_type: mt, meeting: meeting, field_id: field_id} do
      {:ok, _mt} = MeetingTypes.update_meeting_type(mt, %{"custom_fields" => []})

      reloaded = Repo.get!(MeetingSchema, meeting.id)
      assert hd(reloaded.custom_fields_snapshot)["id"] == field_id
      assert reloaded.custom_field_answers[field_id] == "Acme"
    end

    test "changing a field's type does not invalidate past snapshots",
         %{meeting_type: mt, meeting: meeting, field_id: field_id} do
      {:ok, _mt} =
        MeetingTypes.update_meeting_type(mt, %{
          "custom_fields" => [
            %{"id" => field_id, "type" => "number", "label" => "Company"}
          ]
        })

      reloaded = Repo.get!(MeetingSchema, meeting.id)
      assert hd(reloaded.custom_fields_snapshot)["type"] == "short_text"
      assert reloaded.custom_field_answers[field_id] == "Acme"
    end
  end
end
