defmodule Tymeslot.MeetingTypes.UserIdsWithMeetingTypeTest do
  use Tymeslot.DataCase, async: true

  @moduletag :meeting_types

  alias Tymeslot.MeetingTypes

  test "returns, of the given users, those with a meeting type, inactive ones included" do
    two = insert(:user)
    insert(:meeting_type, user: two)
    insert(:meeting_type, user: two)
    inactive = insert(:user)
    insert(:meeting_type, user: inactive, is_active: false)
    none = insert(:user)
    not_asked = insert(:user)
    insert(:meeting_type, user: not_asked)

    assert Enum.sort(MeetingTypes.user_ids_with_meeting_type([two.id, inactive.id, none.id])) ==
             Enum.sort([two.id, inactive.id])
  end

  test "an empty list asks nothing" do
    assert MeetingTypes.user_ids_with_meeting_type([]) == []
  end
end
