defmodule Tymeslot.Meetings.GuestQueriesTest do
  @moduledoc false

  use Tymeslot.DataCase, async: true

  @moduletag :meetings
  @moduletag :queries

  import Tymeslot.Factory

  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests

  describe "rsvp_summaries_for_user/1" do
    test "returns an empty map when the user has no meetings" do
      user = insert(:user)
      assert GuestQueries.rsvp_summaries_for_user(user.id) == %{}
    end

    test "excludes meetings with zero guests from the result" do
      user = insert(:user)
      _empty_meeting = insert(:meeting, organizer_user: user)

      assert GuestQueries.rsvp_summaries_for_user(user.id) == %{}
    end

    test "returns correct totals for a single meeting with mixed RSVP statuses" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)

      {:ok, [g1, g2, _g3]} =
        Guests.create_for_meeting(meeting.id, ~w(a@x.com b@x.com c@x.com))

      {:ok, _rsvp} = Guests.record_rsvp(g1.rsvp_token, "accepted")
      {:ok, _rsvp} = Guests.record_rsvp(g2.rsvp_token, "declined")
      # _g3 remains pending

      summaries = GuestQueries.rsvp_summaries_for_user(user.id)

      uid = meeting.uid
      assert %{^uid => summary} = summaries
      assert summary == %{total: 3, accepted: 1, declined: 1, pending: 1}
    end

    test "keys the result by meeting uid, not meeting id" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      {:ok, _guests} = Guests.create_for_meeting(meeting.id, ["guest@x.com"])

      summaries = GuestQueries.rsvp_summaries_for_user(user.id)

      assert Map.has_key?(summaries, meeting.uid)
      refute Map.has_key?(summaries, meeting.id)
    end

    test "aggregates across multiple meetings for the same user" do
      user = insert(:user)
      t1 = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)
      t2 = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

      meeting1 =
        insert(:meeting,
          organizer_user: user,
          start_time: t1,
          end_time: DateTime.add(t1, 60, :minute)
        )

      meeting2 =
        insert(:meeting,
          organizer_user: user,
          start_time: t2,
          end_time: DateTime.add(t2, 60, :minute)
        )

      {:ok, [g1]} = Guests.create_for_meeting(meeting1.id, ["a@x.com"])
      {:ok, _rsvp} = Guests.record_rsvp(g1.rsvp_token, "accepted")

      {:ok, [g2, _g3]} = Guests.create_for_meeting(meeting2.id, ["b@x.com", "c@x.com"])
      {:ok, _rsvp} = Guests.record_rsvp(g2.rsvp_token, "declined")
      # _g3 remains pending

      summaries = GuestQueries.rsvp_summaries_for_user(user.id)

      uid1 = meeting1.uid
      uid2 = meeting2.uid

      assert %{
               ^uid1 => %{total: 1, accepted: 1, declined: 0, pending: 0},
               ^uid2 => %{total: 2, accepted: 0, declined: 1, pending: 1}
             } = summaries
    end

    test "does not include meetings owned by a different user" do
      user = insert(:user)
      other_user = insert(:user)

      other_meeting = insert(:meeting, organizer_user: other_user)
      {:ok, _guests} = Guests.create_for_meeting(other_meeting.id, ["guest@x.com"])

      assert GuestQueries.rsvp_summaries_for_user(user.id) == %{}
    end

    test "correctly counts when all guests are pending" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      {:ok, _guests} = Guests.create_for_meeting(meeting.id, ["a@x.com", "b@x.com"])

      summaries = GuestQueries.rsvp_summaries_for_user(user.id)

      uid = meeting.uid
      assert %{^uid => %{total: 2, accepted: 0, declined: 0, pending: 2}} = summaries
    end
  end
end
