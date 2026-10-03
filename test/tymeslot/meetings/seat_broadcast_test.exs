defmodule Tymeslot.Meetings.SeatBroadcastTest do
  @moduledoc false

  use ExUnit.Case, async: true

  @moduletag :meetings
  @moduletag :unit

  alias Tymeslot.Meetings.SeatBroadcast

  test "broadcasts {:seat_update, meeting_type_id} on the meeting type's topic" do
    meeting_type_id = System.unique_integer([:positive])
    :ok = Phoenix.PubSub.subscribe(Tymeslot.PubSub, SeatBroadcast.topic(meeting_type_id))

    assert :ok = SeatBroadcast.broadcast_seat_change(meeting_type_id)
    assert_receive {:seat_update, ^meeting_type_id}
  end

  test "topic/1 is stable per meeting type" do
    assert SeatBroadcast.topic(42) == "group_seats:42"
  end
end
