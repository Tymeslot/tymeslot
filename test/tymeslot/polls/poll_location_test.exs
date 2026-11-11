defmodule Tymeslot.Polls.PollLocationTest do
  @moduledoc """
  Where a poll's meeting is held: the location the host gives the poll, the
  meeting type's while it has none of its own, and the meeting a confirmed
  poll creates there.
  """
  use Tymeslot.DataCase, async: false

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Polls
  alias Tymeslot.Polls.{Confirm, PollLocation, PollSchema}
  alias Tymeslot.TestMocks

  @moduletag :polls

  setup do
    TestMocks.resolve_booking_calendars()
    user = insert(:user)
    insert(:profile, user: user)
    insert(:calendar_integration, user: user)
    %{user: user}
  end

  defp attrs(extra) do
    start = DateTime.utc_now() |> DateTime.add(3, :day) |> DateTime.truncate(:second)

    Map.merge(
      %{
        title: "Board dinner",
        duration_minutes: 60,
        timezone: "Europe/Berlin",
        slots: [%{start_time: start}]
      },
      extra
    )
  end

  defp create_with(user, choice, details \\ nil),
    do: Polls.create_poll(user.id, attrs(PollLocation.parse_choice(choice, details)))

  describe "parse_choice/2 and choice/1" do
    test "read the form's value both ways" do
      assert %{location_kind: :video, video_integration_id: 4, venue_id: nil} =
               PollLocation.parse_choice("video:4", nil)

      assert %{location_kind: :in_person, venue_id: 9, video_integration_id: nil} =
               PollLocation.parse_choice("venue:9", "ignored")

      assert %{location_kind: :custom, location_details: "Town hall"} =
               PollLocation.parse_choice("custom", "Town hall")

      assert PollLocation.choice(%PollSchema{location_kind: :video, video_integration_id: 4}) ==
               {"video:4", ""}

      assert PollLocation.choice(%PollSchema{location_kind: :custom, location_details: "Pier 3"}) ==
               {"custom", "Pier 3"}
    end

    test "a forged or empty value is no location of the poll's own" do
      for value <- ["", nil, "venue:abc", "venue:1; drop", "elsewhere:1"] do
        assert %{location_kind: nil, venue_id: nil, video_integration_id: nil} =
                 PollLocation.parse_choice(value, "x")
      end
    end
  end

  describe "creating a poll with a location" do
    test "a saved venue", %{user: user} do
      venue = insert(:venue, user: user, name: "Harbour Hall", description: "Quay 4")

      assert {:ok, poll} = create_with(user, "venue:#{venue.id}")
      assert poll.location_kind == :in_person
      assert poll.venue_id == venue.id

      assert %{kind: :in_person, place: "Harbour Hall (Quay 4)"} = Polls.location(poll)
    end

    test "a place typed in, trimmed", %{user: user} do
      assert {:ok, poll} = create_with(user, "custom", "  Garden pavilion  ")
      assert poll.location_details == "Garden pavilion"
      assert %{kind: :custom, place: "Garden pavilion"} = Polls.location(poll)
    end

    test "a video call", %{user: user} do
      video = insert(:video_integration, user: user, is_active: true)

      assert {:ok, poll} = create_with(user, "video:#{video.id}")
      assert %{kind: :video, place: nil, video_integration_id: id} = Polls.location(poll)
      assert id == video.id
    end

    test "a custom location needs a place", %{user: user} do
      assert {:error, %Changeset{} = changeset} = create_with(user, "custom", "   ")
      assert %{location_details: [_message]} = errors_on(changeset)
    end

    test "another host's venue is refused", %{user: user} do
      venue = insert(:venue, user: insert(:user))
      assert {:error, :location_not_found} = create_with(user, "venue:#{venue.id}")
    end

    test "another host's video integration, or one switched off, is refused", %{user: user} do
      foreign = insert(:video_integration, user: insert(:user), is_active: true)
      off = insert(:video_integration, user: user, is_active: false)

      assert {:error, :location_not_found} = create_with(user, "video:#{foreign.id}")
      assert {:error, :location_not_found} = create_with(user, "video:#{off.id}")
    end

    test "a draft holds its location too", %{user: user} do
      venue = insert(:venue, user: user)

      assert {:ok, draft} =
               Polls.create_draft(
                 user.id,
                 attrs(PollLocation.parse_choice("venue:#{venue.id}", nil))
               )

      assert draft.venue_id == venue.id
      assert PollLocation.choice(draft) == {"venue:#{venue.id}", ""}
    end
  end

  describe "the location in force" do
    test "is the meeting type's while the poll has none of its own", %{user: user} do
      venue = insert(:venue, user: user, name: "Studio", description: nil)
      meeting_type = insert(:meeting_type, user: user, locations: [in_person_location([venue])])
      poll = insert(:poll, user: user, meeting_type_id: meeting_type.id)

      assert %{kind: :in_person, place: "Studio", venue_id: venue_id} = Polls.location(poll)
      assert venue_id == venue.id
    end

    test "is the poll's own over its meeting type's", %{user: user} do
      video = insert(:video_integration, user: user, is_active: true)
      meeting_type = insert(:meeting_type, user: user, locations: [video_location(video)])

      poll =
        insert(:poll,
          user: user,
          meeting_type_id: meeting_type.id,
          location_kind: :custom,
          location_details: "Rooftop"
        )

      assert %{kind: :custom, place: "Rooftop"} = Polls.location(poll)
    end

    test "falls back to the meeting type's once the poll's venue is deleted", %{user: user} do
      gone = insert(:venue, user: user)
      video = insert(:video_integration, user: user, is_active: true)
      meeting_type = insert(:meeting_type, user: user, locations: [video_location(video)])

      {:ok, poll} = create_with(user, "venue:#{gone.id}")
      poll |> Changeset.change(meeting_type_id: meeting_type.id) |> Repo.update!()
      Repo.delete!(gone)

      poll = Repo.get!(PollSchema, poll.id)
      assert poll.venue_id == nil
      assert %{kind: :video} = Polls.location(poll)
    end

    test "is none without a location or a meeting type", %{user: user} do
      assert Polls.location(insert(:poll, user: user)) == nil
    end
  end

  describe "confirming" do
    setup %{user: user} do
      poll = insert(:poll, user: user, status: :open, timezone: "Europe/Berlin")
      start = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

      slot =
        insert(:poll_time_slot,
          poll: poll,
          start_time: start,
          end_time: DateTime.add(start, 3600)
        )

      participant = insert(:poll_participant, poll: poll)
      insert(:poll_vote, participant: participant, time_slot: slot, response: :yes)
      %{poll: poll, slot: slot}
    end

    defp located(poll, changes), do: poll |> Changeset.change(changes) |> Repo.update!()

    test "holds the meeting at the poll's venue", %{user: user, poll: poll, slot: slot} do
      venue = insert(:venue, user: user, name: "Harbour Hall", description: nil)
      located(poll, location_kind: :in_person, venue_id: venue.id)

      assert {:ok, meeting} = Confirm.confirm(poll.id, slot.id, user.id)
      assert meeting.location == "Harbour Hall"
      assert meeting.location_kind == :in_person
      assert meeting.venue_id == venue.id
      assert meeting.video_integration_id == nil
    end

    test "holds the meeting at the place the host typed in", %{user: user, poll: poll, slot: slot} do
      located(poll, location_kind: :custom, location_details: "Garden pavilion")

      assert {:ok, meeting} = Confirm.confirm(poll.id, slot.id, user.id)
      assert meeting.location == "Garden pavilion"
      assert meeting.location_kind == :custom
    end

    test "gives a video call its integration, which creates the room",
         %{user: user, poll: poll, slot: slot} do
      video = insert(:video_integration, user: user, is_active: true)
      located(poll, location_kind: :video, video_integration_id: video.id)

      assert {:ok, meeting} = Confirm.confirm(poll.id, slot.id, user.id)
      assert meeting.video_integration_id == video.id
      assert meeting.location == nil
    end

    test "takes the meeting type's place, not only its video provider",
         %{user: user, poll: poll, slot: slot} do
      venue = insert(:venue, user: user, name: "Studio", description: nil)
      video = insert(:video_integration, user: user, is_active: true)

      meeting_type =
        insert(:meeting_type,
          user: user,
          locations: [in_person_location([venue]), video_location(video, position: 1)]
        )

      located(poll, meeting_type_id: meeting_type.id)

      assert {:ok, meeting} = Confirm.confirm(poll.id, slot.id, user.id)
      assert meeting.location == "Studio"
      assert meeting.venue_id == venue.id
      # The type's first location is the one a booker who changes nothing
      # gets; its video option is not added on top.
      assert meeting.video_integration_id == nil
    end

    test "takes the meeting type's video call", %{user: user, poll: poll, slot: slot} do
      video = insert(:video_integration, user: user, is_active: true)
      meeting_type = insert(:meeting_type, user: user, locations: [video_location(video)])
      located(poll, meeting_type_id: meeting_type.id)

      assert {:ok, meeting} = Confirm.confirm(poll.id, slot.id, user.id)
      assert meeting.video_integration_id == video.id
    end

    test "the poll's own location wins over the meeting type's",
         %{user: user, poll: poll, slot: slot} do
      video = insert(:video_integration, user: user, is_active: true)
      meeting_type = insert(:meeting_type, user: user, locations: [video_location(video)])

      located(poll,
        meeting_type_id: meeting_type.id,
        location_kind: :custom,
        location_details: "Rooftop"
      )

      assert {:ok, meeting} = Confirm.confirm(poll.id, slot.id, user.id)
      assert meeting.location == "Rooftop"
      assert meeting.video_integration_id == nil
    end
  end

  describe "editing an open poll's location" do
    test "switching kinds clears what the old one named", %{user: user} do
      venue = insert(:venue, user: user)
      {:ok, poll} = create_with(user, "venue:#{venue.id}")

      attrs = string_keys(PollLocation.parse_choice("custom", "Boathouse"))
      assert {:ok, updated} = Polls.update_details(poll.id, user.id, attrs)

      assert updated.location_kind == :custom
      assert updated.location_details == "Boathouse"
      assert updated.venue_id == nil
    end

    test "another host's venue is refused, and nothing is saved", %{user: user} do
      {:ok, poll} = create_with(user, "custom", "Boathouse")
      foreign = insert(:venue, user: insert(:user))

      attrs = string_keys(PollLocation.parse_choice("venue:#{foreign.id}", nil))
      assert {:error, :location_not_found} = Polls.update_details(poll.id, user.id, attrs)
      assert Repo.get!(PollSchema, poll.id).location_details == "Boathouse"
    end

    test "an integration switched off since keeps the poll saving its other details",
         %{user: user} do
      video = insert(:video_integration, user: user, is_active: true)
      {:ok, poll} = create_with(user, "video:#{video.id}")
      video |> Changeset.change(is_active: false) |> Repo.update!()

      attrs =
        "video:#{video.id}"
        |> PollLocation.parse_choice(nil)
        |> string_keys()
        |> Map.put("title", "Board dinner, moved")

      assert {:ok, updated} = Polls.update_details(poll.id, user.id, attrs)
      assert updated.title == "Board dinner, moved"
      assert updated.video_integration_id == video.id
    end
  end

  defp string_keys(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
end
