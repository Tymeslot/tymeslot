defmodule Tymeslot.Meetings.SeatsTest do
  use Tymeslot.DataCase, async: true

  @moduletag :meetings

  import Tymeslot.Factory

  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Seats

  describe "seat_level/2" do
    test "green when more than half the seats are free" do
      assert Seats.seat_level(6, 10) == :green
      assert Seats.seat_level(2, 3) == :green
      assert Seats.seat_level(2, 2) == :green
    end

    test "amber when half or fewer seats remain" do
      assert Seats.seat_level(5, 10) == :amber
      assert Seats.seat_level(3, 10) == :amber
      assert Seats.seat_level(2, 4) == :amber
    end

    test "red at twenty percent or fewer seats remaining" do
      assert Seats.seat_level(2, 10) == :red
      assert Seats.seat_level(20, 100) == :red
    end

    test "red on the last seat regardless of capacity" do
      assert Seats.seat_level(1, 2) == :red
      assert Seats.seat_level(1, 3) == :red
      assert Seats.seat_level(1, 999) == :red
    end
  end

  describe "seats_taken/1 and seats_left/2" do
    test "counts live participants plus their guests and derives seats left" do
      meeting = insert(:meeting)
      with_guest = insert(:participant, meeting: meeting)
      _second = insert(:participant, meeting: meeting)

      {:ok, _guest} =
        GuestQueries.insert_guest(%{
          meeting_id: meeting.id,
          email: "plus-one@example.com",
          participant_id: with_guest.id
        })

      assert Seats.seats_taken(meeting.id) == 3
      assert Seats.seats_left(meeting, 10) == 7
    end

    test "seats_left never goes negative when the limit was lowered" do
      meeting = insert(:meeting)
      insert(:participant, meeting: meeting)
      insert(:participant, meeting: meeting)
      insert(:participant, meeting: meeting)

      assert Seats.seats_left(meeting, 2) == 0
    end
  end

  describe "seat_counts_for_range/3" do
    test "returns seats taken keyed by meeting start time" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user)
      start_time = DateTime.utc_now(:second) |> DateTime.add(1, :day)

      meeting =
        insert(:meeting,
          organizer_user: user,
          meeting_type_id: meeting_type.id,
          start_time: start_time,
          end_time: DateTime.add(start_time, 30, :minute)
        )

      insert(:participant, meeting: meeting)

      counts =
        Seats.seat_counts_for_range(
          meeting_type.id,
          DateTime.add(start_time, -1, :hour),
          DateTime.add(start_time, 1, :hour)
        )

      assert %{^start_time => 1} = counts
    end
  end
end
