defmodule Tymeslot.MeetingTypes.BookableMeetingTypesTest do
  @moduledoc """
  `MeetingTypes.get_bookable_meeting_types/1`: the types guests can book now,
  which the calendar's bookable layer and its "Open for booking" kind offer.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :meeting_types

  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes

  test "lists the host's active, unarchived types in their order" do
    user = insert(:user)
    second = insert(:meeting_type, user: user, name: "Workshop", sort_order: 2)
    first = insert(:meeting_type, user: user, name: "Intro call", sort_order: 1)
    insert(:meeting_type, user: user, name: "Paused", is_active: false, sort_order: 0)
    insert(:meeting_type, user: user, name: "Old", is_archived: true, sort_order: 0)
    insert(:meeting_type, name: "Someone else's", sort_order: 0)

    assert Enum.map(MeetingTypes.get_bookable_meeting_types(user.id), & &1.id) == [
             first.id,
             second.id
           ]
  end
end
