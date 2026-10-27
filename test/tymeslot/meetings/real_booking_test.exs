defmodule Tymeslot.Meetings.RealBookingTest do
  use Tymeslot.DataCase, async: true

  @moduletag :meetings

  alias Tymeslot.Meetings

  defp host, do: insert(:user, email: "host#{System.unique_integer([:positive])}@example.com")

  defp booked?(user), do: Meetings.organisers_with_real_booking([user.id]) == [user.id]

  defp group_meeting(user, attrs \\ []),
    do: insert(:group_meeting, [organizer_user: user, organizer_email: user.email] ++ attrs)

  test "a one-to-one booking by someone else counts" do
    user = host()

    insert(:meeting,
      organizer_user: user,
      organizer_email: user.email,
      attendee_email: "guest@example.com"
    )

    assert booked?(user)
  end

  test "a host booking their own page does not count" do
    user = host()

    insert(:meeting,
      organizer_user: user,
      organizer_email: user.email,
      attendee_email: user.email
    )

    refute booked?(user)
  end

  test "a cancelled booking does not count" do
    user = host()

    insert(:meeting,
      organizer_user: user,
      organizer_email: user.email,
      attendee_email: "guest@example.com",
      status: "cancelled"
    )

    refute booked?(user)
  end

  test "a group meeting counts once someone other than the organiser holds a seat" do
    user = host()
    meeting = group_meeting(user)
    insert(:participant, meeting: meeting, email: user.email)
    refute booked?(user)

    insert(:participant, meeting: meeting, email: "guest@example.com")
    assert booked?(user)
  end

  test "a group seat given up does not count" do
    user = host()

    insert(:participant,
      meeting: group_meeting(user),
      email: "guest@example.com",
      cancelled_at: DateTime.utc_now(:second)
    )

    refute booked?(user)
  end

  test "a cancelled group meeting does not count, whatever its participants" do
    user = host()

    insert(:participant,
      meeting: group_meeting(user, status: "cancelled"),
      email: "guest@example.com"
    )

    refute booked?(user)
  end

  test "returns only the given organisers, once each" do
    user = host()
    other = host()

    for days <- 1..2 do
      start_time = DateTime.add(DateTime.utc_now(:second), days, :day)

      insert(:meeting,
        organizer_user: user,
        organizer_email: user.email,
        attendee_email: "a@example.com",
        start_time: start_time,
        end_time: DateTime.add(start_time, 60, :minute)
      )
    end

    insert(:meeting,
      organizer_user: other,
      organizer_email: other.email,
      attendee_email: "b@example.com"
    )

    assert Meetings.organisers_with_real_booking([user.id]) == [user.id]
    assert Meetings.organisers_with_real_booking([]) == []
  end
end
