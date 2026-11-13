defmodule Tymeslot.Bookings.CreateAdHocLocationTest do
  @moduledoc """
  Where a meeting the organiser creates themselves is held
  (`CreateAdHoc`'s `:location`): one of their saved venues, or a place they
  typed in, filling the meeting's location fields as a booking on a meeting
  type fills them.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :bookings

  import Tymeslot.Factory

  alias Tymeslot.Bookings.CreateAdHoc
  alias Tymeslot.Venues

  setup do
    user = insert(:user)
    insert(:profile, user: user, username: "adhoc-location-host")

    start = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

    params = %{
      title: "Planning",
      start_time: start,
      end_time: DateTime.add(start, 1, :hour),
      attendee_name: "Jane Doe",
      attendee_email: "jane@example.com",
      organizer_user_id: user.id
    }

    %{user: user, params: params}
  end

  test "a saved venue is the meeting's place, named as the booking page names it", ctx do
    {:ok, venue} =
      Venues.create_venue(ctx.user.id, %{name: "Head office", description: "Main St 1\nBerlin"})

    assert {:ok, meeting} =
             CreateAdHoc.execute(Map.put(ctx.params, :location, {:venue, venue.id}))

    assert meeting.location == "Head office (Main St 1, Berlin)"
    assert meeting.location_kind == :in_person
    assert meeting.venue_id == venue.id
  end

  test "another host's venue is refused and no meeting is created", ctx do
    {:ok, foreign} = Venues.create_venue(insert(:user).id, %{name: "Not yours"})

    assert {:error, :invalid_location} =
             CreateAdHoc.execute(Map.put(ctx.params, :location, {:venue, foreign.id}))

    refute Repo.exists?(Tymeslot.Meetings.MeetingSchema)
  end

  test "a place typed in is kept as written, trimmed", ctx do
    assert {:ok, meeting} =
             CreateAdHoc.execute(Map.put(ctx.params, :location, {:custom, "  Room 4.12  "}))

    assert meeting.location == "Room 4.12"
    assert meeting.location_kind == :custom
    assert meeting.venue_id == nil
  end

  test "a blank place, or none, leaves the location empty", ctx do
    assert {:ok, blank} = CreateAdHoc.execute(Map.put(ctx.params, :location, {:custom, "  "}))
    assert {blank.location, blank.location_kind} == {nil, nil}

    later = %{
      ctx.params
      | start_time: DateTime.add(ctx.params.start_time, 1, :day),
        end_time: DateTime.add(ctx.params.end_time, 1, :day)
    }

    assert {:ok, none} = CreateAdHoc.execute(later)
    assert {none.location, none.location_kind} == {nil, nil}
  end

  test "a place longer than a location may be is refused", ctx do
    too_long = String.duplicate("a", CreateAdHoc.custom_location_max_length() + 1)

    assert {:error, :invalid_location} =
             CreateAdHoc.execute(Map.put(ctx.params, :location, {:custom, too_long}))
  end

  test "anything else as a location is refused", ctx do
    assert {:error, :invalid_location} =
             CreateAdHoc.execute(Map.put(ctx.params, :location, {:venue, "1"}))
  end
end
