defmodule Tymeslot.Meetings.MeetingListQueriesTest do
  @moduledoc """
  Coverage for the visibility rules in
  `MeetingListQueries.list_meetings_for_user_paginated_cursor/2` on a group
  meeting: the organiser gets the full roster, and a participant's email
  never matches the meeting row, whose attendee columns are always empty.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :meetings
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingListQueries

  defp slot_in(days) do
    start_time = DateTime.utc_now() |> DateTime.add(days, :day) |> DateTime.truncate(:second)
    [start_time: start_time, end_time: DateTime.add(start_time, 30, :minute)]
  end

  setup do
    organizer = insert(:user)
    _profile = insert(:profile, user: organizer)
    meeting_type = insert(:meeting_type, user: organizer, max_participants: 4)

    meeting =
      insert(
        :group_meeting,
        [
          capacity: 4,
          organizer_user_id: organizer.id,
          organizer_email: organizer.email,
          meeting_type_ref: meeting_type
        ] ++ slot_in(3)
      )

    for {email, guest} <- [
          {"first@example.com", "first-plus-one@example.com"},
          {"other@example.com", "other-plus-one@example.com"}
        ] do
      participant = insert(:participant, meeting: meeting, email: email)
      {:ok, _guests} = Guests.create_for_participant(meeting.id, participant.id, [guest])
    end

    %{organizer: organizer, meeting: meeting}
  end

  describe "list_meetings_for_user_paginated_cursor/2" do
    test "the organiser sees the full participant and guest roster", %{
      organizer: organizer,
      meeting: meeting
    } do
      assert [%{id: id} = loaded] =
               MeetingListQueries.list_meetings_for_user_paginated_cursor(organizer.email, [])

      assert id == meeting.id

      assert loaded.participants |> Enum.map(& &1.email) |> Enum.sort() ==
               ["first@example.com", "other@example.com"]

      assert loaded.guests |> Enum.map(& &1.email) |> Enum.sort() ==
               ["first-plus-one@example.com", "other-plus-one@example.com"]
    end

    test "a participant's email does not match the group meeting row" do
      assert MeetingListQueries.list_meetings_for_user_paginated_cursor(
               "first@example.com",
               []
             ) == []
    end
  end
end
