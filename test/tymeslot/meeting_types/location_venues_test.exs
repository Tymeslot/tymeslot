defmodule Tymeslot.MeetingTypes.LocationVenuesTest do
  @moduledoc """
  The saved venues an in-person location offers, and how a booker's venue
  choice is resolved against them. Driven through `Tymeslot.MeetingTypes`
  with real venues, because what counts as offered depends on which venues
  still exist for the owner.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :meeting_types

  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo
  alias Tymeslot.Venues

  setup do
    user = insert(:user)

    berlin =
      insert(:venue,
        user: user,
        name: "Berlin office",
        description: "Friedrichstrasse 1",
        position: 0
      )

    munich = insert(:venue, user: user, name: "Munich office", description: nil, position: 1)

    meeting_type =
      insert(:meeting_type,
        user: user,
        locations: [
          in_person_location([berlin, munich], id: "loc-offices", label: "Our offices"),
          in_person_location([], id: "loc-arranged", label: "In person", position: 1)
        ]
      )

    %{user: user, berlin: berlin, munich: munich, meeting_type: meeting_type}
  end

  defp resolve(meeting_type, choice),
    do:
      MeetingTypes.resolve_location(meeting_type, Map.put_new(choice, :option_id, "loc-offices"))

  describe "location_venue_choices/1" do
    test "lists each in-person location's venues in the organiser's library order", ctx do
      assert %{"loc-offices" => [first, second]} =
               MeetingTypes.location_venue_choices(ctx.meeting_type)

      assert first == %{
               id: ctx.berlin.id,
               name: "Berlin office",
               description: "Friedrichstrasse 1"
             }

      assert second.id == ctx.munich.id
    end

    test "follows the library when the organiser reorders it", ctx do
      assert {:ok, _count} = Venues.reorder_venues(ctx.user.id, [ctx.munich.id, ctx.berlin.id])

      assert %{"loc-offices" => [%{id: first_id}, %{id: second_id}]} =
               MeetingTypes.location_venue_choices(ctx.meeting_type)

      assert [first_id, second_id] == [ctx.munich.id, ctx.berlin.id]
      assert %{venue_id: opens_on} = resolve(ctx.meeting_type, %{})
      assert opens_on == ctx.munich.id
    end

    test "leaves out a location with no venues", ctx do
      refute Map.has_key?(MeetingTypes.location_venue_choices(ctx.meeting_type), "loc-arranged")
    end

    test "leaves out a venue that no longer exists", ctx do
      Repo.delete!(ctx.munich)

      assert %{"loc-offices" => [%{id: id}]} =
               MeetingTypes.location_venue_choices(ctx.meeting_type)

      assert id == ctx.berlin.id
    end

    test "never offers another owner's venue, even if a location lists it", ctx do
      foreign = insert(:venue)

      meeting_type =
        insert(:meeting_type,
          user: ctx.user,
          locations: [in_person_location([foreign], id: "loc-foreign")]
        )

      assert MeetingTypes.location_venue_choices(meeting_type) == %{}
    end

    test "offers nothing without a meeting type" do
      assert MeetingTypes.location_venue_choices(nil) == %{}
    end
  end

  describe "resolve_location/2 with venues" do
    test "books the venue the booker picked", ctx do
      assert %{venue_id: venue_id, location: "Munich office", location_kind: "in_person"} =
               resolve(ctx.meeting_type, %{venue_id: ctx.munich.id})

      assert venue_id == ctx.munich.id
    end

    test "accepts the pick as the string the form posts", ctx do
      assert %{venue_id: venue_id} =
               resolve(ctx.meeting_type, %{venue_id: to_string(ctx.munich.id)})

      assert venue_id == ctx.munich.id
    end

    test "books the first venue when none was picked", ctx do
      assert %{venue_id: venue_id, location: "Berlin office (Friedrichstrasse 1)"} =
               resolve(ctx.meeting_type, %{})

      assert venue_id == ctx.berlin.id
    end

    test "a forged venue id books the first venue instead", ctx do
      assert %{venue_id: venue_id} = resolve(ctx.meeting_type, %{venue_id: 987_654_321})
      assert venue_id == ctx.berlin.id
    end

    test "another owner's venue is not honoured", ctx do
      assert %{venue_id: venue_id} = resolve(ctx.meeting_type, %{venue_id: insert(:venue).id})
      assert venue_id == ctx.berlin.id
    end

    test "the host's own venue that this location does not list is not honoured", ctx do
      elsewhere = insert(:venue, user: ctx.user, name: "Hamburg office")

      assert %{venue_id: venue_id} = resolve(ctx.meeting_type, %{venue_id: elsewhere.id})
      assert venue_id == ctx.berlin.id
    end

    test "a deleted venue is skipped for the next one still listed", ctx do
      Repo.delete!(ctx.berlin)

      assert %{venue_id: venue_id, location: "Munich office"} =
               resolve(ctx.meeting_type, %{venue_id: ctx.berlin.id})

      assert venue_id == ctx.munich.id
    end

    test "with every venue gone the booking has no address and no venue", ctx do
      Repo.delete!(ctx.berlin)
      Repo.delete!(ctx.munich)

      assert %{venue_id: nil, location: "Our offices"} = resolve(ctx.meeting_type, %{})
    end

    test "a location with no venues books its label with no venue", ctx do
      assert %{venue_id: nil, location: "In person", location_option_id: "loc-arranged"} =
               resolve(ctx.meeting_type, %{option_id: "loc-arranged", venue_id: ctx.berlin.id})
    end

    test "keeps the current venue when the submitted one is not offered", ctx do
      assert %{venue_id: venue_id} =
               resolve(ctx.meeting_type, %{venue_id: 987_654_321, current_venue_id: ctx.munich.id})

      assert venue_id == ctx.munich.id
    end
  end
end
