defmodule Tymeslot.Meetings.GuestSeatsTest do
  @moduledoc """
  The seats a group booking's guests hold: every guest holds one until they
  decline, a decline gives it back to the slot, and a guest who declined can
  answer yes again only while a seat is free.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :meetings

  import Tymeslot.Factory

  alias Tymeslot.Meetings.GroupScheduling
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.SeatBroadcast
  alias Tymeslot.Meetings.Seats

  # A slot of three seats: Ada with her guest Charles, and Bob.
  setup do
    user = insert(:user)
    meeting_type = insert(:meeting_type, user: user, max_participants: 3)

    meeting =
      insert(:meeting,
        organizer_user: user,
        organizer_email: user.email,
        meeting_type_ref: meeting_type,
        capacity: 3
      )

    ada = insert(:participant, meeting: meeting, name: "Ada", email: "ada@example.com")
    insert(:participant, meeting: meeting, name: "Bob", email: "bob@example.com")
    {:ok, [charles]} = Guests.create_for_participant(meeting.id, ada.id, ["charles@example.com"])

    %{meeting: meeting, meeting_type: meeting_type, ada: ada, charles: charles}
  end

  defp seats_taken_in_range(ctx) do
    from = DateTime.add(ctx.meeting.start_time, -1, :hour)
    to = DateTime.add(ctx.meeting.start_time, 1, :hour)

    ctx.meeting_type.id
    |> Seats.seat_counts_for_range(from, to)
    |> Map.get(ctx.meeting.start_time, 0)
  end

  test "a guest holds a seat until they decline, and a decline gives it back", ctx do
    assert Seats.seats_taken(ctx.meeting.id) == 3
    assert seats_taken_in_range(ctx) == 3
    refute GroupScheduling.join_target(ctx.meeting_type.id, ctx.meeting.start_time, 1)

    assert {:ok, %{status: "accepted"}} = Guests.record_rsvp(ctx.charles.rsvp_token, "accepted")
    assert Seats.seats_taken(ctx.meeting.id) == 3

    assert {:ok, %{status: "declined"}} = Guests.record_rsvp(ctx.charles.rsvp_token, "declined")
    assert Seats.seats_taken(ctx.meeting.id) == 2
    assert seats_taken_in_range(ctx) == 2
    assert GroupScheduling.join_target(ctx.meeting_type.id, ctx.meeting.start_time, 1)
  end

  test "counts loaded lists the same way" do
    assert Seats.seats_taken([:ada], [%{status: "pending"}, %{status: "accepted"}]) == 3
    assert Seats.seats_taken([:ada], [%{status: "declined"}]) == 1
  end

  test "a decline tells open booking pages that a seat is free", ctx do
    Phoenix.PubSub.subscribe(Tymeslot.PubSub, SeatBroadcast.topic(ctx.meeting_type.id))

    {:ok, _declined} = Guests.record_rsvp(ctx.charles.rsvp_token, "declined")

    meeting_type_id = ctx.meeting_type.id
    assert_receive {:seat_update, ^meeting_type_id}
  end

  test "a guest who declined can answer yes again while a seat is free", ctx do
    {:ok, _declined} = Guests.record_rsvp(ctx.charles.rsvp_token, "declined")
    {:ok, guest} = Guests.get_open_invitation(ctx.charles.rsvp_token)
    assert Guests.can_accept?(guest)

    assert {:ok, %{status: "accepted"}} = Guests.record_rsvp(ctx.charles.rsvp_token, "accepted")
    assert Seats.seats_taken(ctx.meeting.id) == 3
  end

  test "but not once their seat has gone to someone else", ctx do
    {:ok, _declined} = Guests.record_rsvp(ctx.charles.rsvp_token, "declined")
    insert(:participant, meeting: ctx.meeting, name: "Grace", email: "grace@example.com")

    {:ok, guest} = Guests.get_open_invitation(ctx.charles.rsvp_token)
    refute Guests.can_accept?(guest)

    assert {:error, :full} = Guests.record_rsvp(ctx.charles.rsvp_token, "accepted")
    assert {:ok, %{status: "declined"}} = GuestQueries.get_by_token(ctx.charles.rsvp_token)
    assert Seats.seats_taken(ctx.meeting.id) == 3
  end
end
