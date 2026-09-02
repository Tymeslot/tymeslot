defmodule Tymeslot.Meetings.MeetingListQueriesTest do
  @moduledoc """
  Coverage for the cross-user visibility rules in
  `MeetingListQueries.list_meetings_for_user_paginated_cursor/2`.

  A meeting converted from a 1:1 into a group keeps its original attendee
  matching the "meetings for this user" query even though they are now just
  one participant among several. The organiser gets the full roster; the
  original attendee must not.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :meetings
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.Meetings.GroupConversion
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingListQueries
  alias Tymeslot.Meetings.ParticipantQueries

  defp slot_in(days) do
    start_time = DateTime.utc_now() |> DateTime.add(days, :day) |> DateTime.truncate(:second)
    [start_time: start_time, end_time: DateTime.add(start_time, 30, :minute)]
  end

  setup do
    organizer = insert(:user)
    _profile = insert(:profile, user: organizer)
    meeting_type = insert(:meeting_type, user: organizer, max_participants: 1)

    meeting =
      insert(
        :meeting,
        [
          organizer_user_id: organizer.id,
          organizer_email: organizer.email,
          meeting_type_ref: meeting_type,
          attendee_name: "Original Booker",
          attendee_email: "original-booker@example.com"
        ] ++ slot_in(3)
      )

    {:ok, _guests} = Guests.create_for_meeting(meeting.id, ["original-plus-one@example.com"])

    # Convert the type to group: the original booker gets a participant row
    # built from their attendee columns and their guest is adopted.
    {:ok, _conversion} = GroupConversion.backfill(meeting_type.id, 4)

    [original_participant] = ParticipantQueries.list_live_for_meeting(meeting.id)

    other_participant =
      insert(:participant, meeting: meeting, name: "Other Joiner", email: "other@example.com")

    {:ok, _other_guests} =
      Guests.create_for_participant(meeting.id, other_participant.id, [
        "other-plus-one@example.com"
      ])

    %{
      organizer: organizer,
      meeting: meeting,
      original_participant: original_participant,
      other_participant: other_participant
    }
  end

  describe "list_meetings_for_user_paginated_cursor/2" do
    test "the organiser sees the full participant and guest roster", %{
      organizer: organizer,
      meeting: meeting
    } do
      assert [%{id: id} = loaded] =
               MeetingListQueries.list_meetings_for_user_paginated_cursor(organizer.email)

      assert id == meeting.id
      assert length(loaded.participants) == 2
      participant_emails = Enum.map(loaded.participants, & &1.email)
      assert "original-booker@example.com" in participant_emails
      assert "other@example.com" in participant_emails

      guest_emails = Enum.map(loaded.guests, & &1.email)
      assert "original-plus-one@example.com" in guest_emails
      assert "other-plus-one@example.com" in guest_emails
    end

    test "the demoted original attendee sees no participant roster and only their own guest" do
      assert [loaded] =
               MeetingListQueries.list_meetings_for_user_paginated_cursor(
                 "original-booker@example.com"
               )

      assert loaded.participants == []
      assert Enum.map(loaded.guests, & &1.email) == ["original-plus-one@example.com"]
    end
  end
end
