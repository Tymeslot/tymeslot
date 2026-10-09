defmodule Tymeslot.Meetings.GroupMeetingQueriesTest do
  @moduledoc false

  use Tymeslot.DataCase, async: true

  @moduletag :meetings
  @moduletag :queries

  import Tymeslot.Factory

  alias Tymeslot.Meetings.GroupMeetingQueries
  alias Tymeslot.Repo

  defp start_at(days, hour) do
    DateTime.utc_now()
    |> DateTime.add(days, :day)
    |> then(&%{&1 | hour: hour, minute: 0, second: 0, microsecond: {0, 0}})
  end

  defp insert_group_meeting(user, meeting_type, start_time, attrs \\ %{}) do
    insert(
      :meeting,
      Map.merge(
        %{
          organizer_user_id: user.id,
          meeting_type_ref: meeting_type,
          start_time: start_time,
          end_time: DateTime.add(start_time, 30, :minute),
          status: "confirmed"
        },
        attrs
      )
    )
  end

  setup do
    user = insert(:user)
    meeting_type = insert(:meeting_type, user: user, max_participants: 4)
    %{user: user, meeting_type: meeting_type}
  end

  describe "get_live_for_update/2" do
    test "returns the live meeting at the exact start time inside a transaction",
         %{user: user, meeting_type: meeting_type} do
      start_time = start_at(3, 10)
      meeting = insert_group_meeting(user, meeting_type, start_time)

      {:ok, found} =
        Repo.transaction(fn ->
          GroupMeetingQueries.get_live_for_update(meeting_type.id, start_time)
        end)

      assert %{id: found_id} = found
      assert found_id == meeting.id
    end

    test "ignores cancelled meetings and meetings of other types",
         %{user: user, meeting_type: meeting_type} do
      start_time = start_at(3, 10)
      other_type = insert(:meeting_type, user: user, max_participants: 4)
      insert_group_meeting(user, meeting_type, start_time, %{status: "cancelled"})
      insert_group_meeting(user, other_type, DateTime.add(start_time, 2, :hour))

      {:ok, found} =
        Repo.transaction(fn ->
          GroupMeetingQueries.get_live_for_update(meeting_type.id, start_time)
        end)

      assert found == nil
    end

    test "ignores meetings whose slot is voided by a pending reschedule request",
         %{user: user, meeting_type: meeting_type} do
      start_time = start_at(3, 10)

      insert_group_meeting(user, meeting_type, start_time, %{
        reschedule_requested_at: DateTime.utc_now(:second)
      })

      {:ok, found} =
        Repo.transaction(fn ->
          GroupMeetingQueries.get_live_for_update(meeting_type.id, start_time)
        end)

      assert found == nil
    end
  end

  describe "get_live_at/2" do
    test "returns the live meeting without requiring a transaction",
         %{user: user, meeting_type: meeting_type} do
      start_time = start_at(4, 9)
      meeting = insert_group_meeting(user, meeting_type, start_time)

      assert %{id: found_id} = GroupMeetingQueries.get_live_at(meeting_type.id, start_time)
      assert found_id == meeting.id
      assert GroupMeetingQueries.get_live_at(meeting_type.id, start_at(4, 11)) == nil
    end
  end

  describe "list_live_for_type_in_range/3" do
    test "returns live meetings of the type inside the window, ordered by start",
         %{user: user, meeting_type: meeting_type} do
      inside_a = insert_group_meeting(user, meeting_type, start_at(3, 14))
      inside_b = insert_group_meeting(user, meeting_type, start_at(3, 9))
      _outside = insert_group_meeting(user, meeting_type, start_at(9, 9))

      _cancelled =
        insert_group_meeting(user, meeting_type, start_at(3, 16), %{status: "cancelled"})

      result =
        GroupMeetingQueries.list_live_for_type_in_range(
          meeting_type.id,
          start_at(3, 0),
          start_at(3, 23)
        )

      assert Enum.map(result, & &1.id) == [inside_b.id, inside_a.id]
    end
  end
end
