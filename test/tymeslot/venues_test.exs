defmodule Tymeslot.VenuesTest do
  @moduledoc """
  The organiser's library of saved in-person locations: owner scoping, the
  changeset rules, and the one-line form a venue takes on a meeting.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :meeting_types

  import Tymeslot.Factory

  alias Tymeslot.Repo
  alias Tymeslot.Venues
  alias Tymeslot.Venues.VenueSchema

  describe "create_venue/2" do
    test "saves a venue for its owner, trimmed" do
      user = insert(:user)

      assert {:ok, venue} =
               Venues.create_venue(user.id, %{
                 "name" => "  Berlin office ",
                 "description" => " Friedrichstrasse 1\n3rd floor  "
               })

      assert venue.user_id == user.id
      assert venue.name == "Berlin office"
      assert venue.description == "Friedrichstrasse 1\n3rd floor"
    end

    test "requires a name" do
      assert {:error, changeset} = Venues.create_venue(insert(:user).id, %{"name" => "   "})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "limits the name to 120 characters and the description to 500" do
      assert {:error, changeset} =
               Venues.create_venue(insert(:user).id, %{
                 "name" => String.duplicate("a", 121),
                 "description" => String.duplicate("b", 501)
               })

      assert %{
               name: ["should be at most 120 character(s)"],
               description: ["should be at most 500 character(s)"]
             } = errors_on(changeset)
    end

    test "stores a blank description as none" do
      {:ok, venue} =
        Venues.create_venue(insert(:user).id, %{"name" => "Studio", "description" => "  "})

      assert venue.description == nil
    end

    test "refuses a second venue with the same name for the same owner" do
      user = insert(:user)

      assert {:ok, _first} = Venues.create_venue(user.id, %{"name" => "Studio"})
      assert {:error, changeset} = Venues.create_venue(user.id, %{"name" => "Studio"})
      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end

    test "refuses a second venue whose name differs only in case" do
      user = insert(:user)

      assert {:ok, _first} = Venues.create_venue(user.id, %{"name" => "Studio"})
      assert {:error, changeset} = Venues.create_venue(user.id, %{"name" => "studio"})
      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end

    test "lets two owners each have a venue with the same name" do
      assert {:ok, _first} = Venues.create_venue(insert(:user).id, %{"name" => "Studio"})
      assert {:ok, _second} = Venues.create_venue(insert(:user).id, %{"name" => "Studio"})
    end

    test "strips null bytes, which the database refuses" do
      {:ok, venue} = Venues.create_venue(insert(:user).id, %{"name" => "Stu\x00dio"})

      assert venue.name == "Studio"
    end
  end

  describe "list_venues/1" do
    test "lists only the owner's venues, by position and then by id" do
      user = insert(:user)
      insert(:venue, user: user, name: "Munich office", position: 1)
      insert(:venue, user: user, name: "Berlin office", position: 0)
      insert(:venue, user: user, name: "Hamburg office", position: 1)
      insert(:venue, name: "Somebody else's office", position: 0)

      assert ["Berlin office", "Munich office", "Hamburg office"] =
               user.id |> Venues.list_venues() |> Enum.map(& &1.name)
    end

    test "puts a new venue last" do
      user = insert(:user)
      insert(:venue, user: user, name: "Berlin office", position: 4)

      assert {:ok, studio} = Venues.create_venue(user.id, %{"name" => "Studio"})
      assert studio.position == 5
      assert ["Berlin office", "Studio"] = user.id |> Venues.list_venues() |> Enum.map(& &1.name)
    end

    test "gives an owner's first venue position 0, whatever other owners have" do
      insert(:venue, position: 9)

      assert {:ok, first} = Venues.create_venue(insert(:user).id, %{"name" => "Studio"})
      assert first.position == 0
    end
  end

  describe "reorder_venues/2" do
    setup do
      user = insert(:user)
      berlin = insert(:venue, user: user, name: "Berlin office", position: 0)
      munich = insert(:venue, user: user, name: "Munich office", position: 1)
      hamburg = insert(:venue, user: user, name: "Hamburg office", position: 2)

      %{user: user, berlin: berlin, munich: munich, hamburg: hamburg}
    end

    defp names(user), do: user.id |> Venues.list_venues() |> Enum.map(& &1.name)

    test "puts the venues in the order given, ids as strings included", ctx do
      assert {:ok, 3} =
               Venues.reorder_venues(ctx.user.id, [
                 to_string(ctx.hamburg.id),
                 ctx.berlin.id,
                 ctx.munich.id
               ])

      assert names(ctx.user) == ["Hamburg office", "Berlin office", "Munich office"]

      assert ctx.user.id |> Venues.list_venues() |> Enum.map(& &1.position) == [0, 1, 2]
    end

    test "ignores another owner's venue and leaves it where it was", ctx do
      foreign = insert(:venue, name: "Somebody else's office", position: 7)

      assert {:ok, 3} =
               Venues.reorder_venues(ctx.user.id, [foreign.id, ctx.munich.id, ctx.berlin.id])

      assert names(ctx.user) == ["Munich office", "Berlin office", "Hamburg office"]
      assert [%{position: 7}] = Venues.list_venues(foreign.user_id)
    end

    test "keeps venues left out of the list after the listed ones, in their order", ctx do
      assert {:ok, 3} = Venues.reorder_venues(ctx.user.id, [ctx.hamburg.id, "not-an-id"])

      assert names(ctx.user) == ["Hamburg office", "Berlin office", "Munich office"]
      assert ctx.user.id |> Venues.list_venues() |> Enum.map(& &1.position) == [0, 1, 2]
    end
  end

  describe "get_venue/2" do
    test "gets an owned venue by id, including an id given as a string" do
      venue = insert(:venue)

      assert {:ok, %VenueSchema{id: id}} = Venues.get_venue(venue.user_id, to_string(venue.id))
      assert id == venue.id
    end

    test "does not get another owner's venue" do
      venue = insert(:venue)

      assert {:error, :not_found} = Venues.get_venue(insert(:user).id, venue.id)
    end

    test "does not get a venue from an id that is not a number" do
      assert {:error, :not_found} = Venues.get_venue(insert(:user).id, "office")
    end

    test "does not get a venue from an id beyond the database's range" do
      user = insert(:user)

      assert {:error, :not_found} = Venues.get_venue(user.id, "99999999999999999999")
      assert {:error, :not_found} = Venues.get_venue(user.id, 99_999_999_999_999_999_999)
    end
  end

  describe "update_venue/2" do
    test "renames and re-describes a venue" do
      venue = insert(:venue, name: "Studio", description: "Old Street 1")

      assert {:ok, updated} =
               Venues.update_venue(venue, %{"name" => "The studio", "description" => ""})

      assert updated.name == "The studio"
      assert updated.description == nil
    end

    test "refuses a blank name" do
      venue = insert(:venue)

      assert {:error, changeset} = Venues.update_venue(venue, %{"name" => "  "})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "refuses a name another of the owner's venues has" do
      user = insert(:user)
      insert(:venue, user: user, name: "Studio")
      venue = insert(:venue, user: user, name: "Office")

      assert {:error, changeset} = Venues.update_venue(venue, %{"name" => "Studio"})
      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end

    test "cannot move a venue to another owner" do
      venue = insert(:venue)
      other = insert(:user)

      assert {:ok, updated} = Venues.update_venue(venue, %{"user_id" => other.id})
      assert updated.user_id == venue.user_id
    end
  end

  describe "delete_venue/1" do
    test "deletes a venue no meeting type offers" do
      venue = insert(:venue)

      assert {:ok, _deleted} = Venues.delete_venue(venue)
      assert {:error, :not_found} = Venues.get_venue(venue.user_id, venue.id)
    end
  end

  describe "delete_venue/1 while meeting types offer the venue" do
    test "is refused, naming the meeting types" do
      user = insert(:user)
      venue = insert(:venue, user: user)

      insert(:meeting_type,
        user: user,
        name: "Consultation",
        locations: [in_person_location([venue])]
      )

      assert {:error, {:in_use, [%{name: "Consultation"}]}} = Venues.delete_venue(venue)
      assert {:ok, _still_there} = Venues.get_venue(user.id, venue.id)
    end
  end

  describe "usage_counts/1 and meeting_types_using/1" do
    test "count each meeting type once, however many of its locations list the venue" do
      user = insert(:user)
      berlin = insert(:venue, user: user)
      munich = insert(:venue, user: user)
      unused = insert(:venue, user: user)

      insert(:meeting_type,
        user: user,
        name: "Consultation",
        locations: [
          in_person_location([berlin, munich]),
          in_person_location([berlin], position: 1)
        ]
      )

      insert(:meeting_type,
        user: user,
        name: "Workshop",
        locations: [in_person_location([berlin])]
      )

      counts = Venues.usage_counts(user.id)

      assert counts[berlin.id] == 2
      assert counts[munich.id] == 1
      refute Map.has_key?(counts, unused.id)

      assert ["Consultation", "Workshop"] =
               berlin |> Venues.meeting_types_using() |> Enum.map(& &1.name)

      assert Venues.meeting_types_using(unused) == []
    end

    test "never count another owner's meeting types" do
      venue = insert(:venue)
      insert(:meeting_type, user: insert(:user), locations: [in_person_location([venue])])

      assert Venues.usage_counts(venue.user_id) == %{}
      assert Venues.meeting_types_using(venue) == []
    end

    test "tolerate a stored in-person location with no venue_ids key at all" do
      user = insert(:user)
      venue = insert(:venue, user: user)
      meeting_type = insert(:meeting_type, user: user, name: "Legacy")

      store_raw_locations(meeting_type, [
        %{"id" => "loc-1", "kind" => "in_person", "label" => "In person", "position" => 0}
      ])

      assert Venues.usage_counts(user.id) == %{}
      assert Venues.meeting_types_using(venue) == []
    end

    test "ignore venue_ids stored on a location that is not in person" do
      user = insert(:user)
      venue = insert(:venue, user: user)
      meeting_type = insert(:meeting_type, user: user, name: "Stray")

      store_raw_locations(meeting_type, [
        %{"id" => "loc-1", "kind" => "video", "label" => "Video", "venue_ids" => [venue.id]},
        %{"id" => "loc-2", "kind" => "custom", "label" => "Other", "venue_ids" => [venue.id]}
      ])

      assert Venues.usage_counts(user.id) == %{}
      assert Venues.meeting_types_using(venue) == []
      assert {:ok, _deleted} = Venues.delete_venue(venue)
    end

    test "count only numeric venue ids, as the delete check matches them" do
      user = insert(:user)
      venue = insert(:venue, user: user)
      meeting_type = insert(:meeting_type, user: user, name: "Strings")

      store_raw_locations(meeting_type, [
        %{
          "id" => "loc-1",
          "kind" => "in_person",
          "label" => "In person",
          "venue_ids" => [to_string(venue.id), "office", 7.5]
        }
      ])

      assert Venues.usage_counts(user.id) == %{}
      assert Venues.meeting_types_using(venue) == []
    end
  end

  describe "owns_all?/2" do
    test "is true for none at all and for the owner's own venues" do
      user = insert(:user)
      first = insert(:venue, user: user)
      second = insert(:venue, user: user)

      assert Venues.owns_all?(user.id, [])
      assert Venues.owns_all?(user.id, [first.id, second.id, first.id])
    end

    test "is false when any id is someone else's or does not exist" do
      user = insert(:user)
      own = insert(:venue, user: user)
      foreign = insert(:venue)

      refute Venues.owns_all?(user.id, [own.id, foreign.id])
      refute Venues.owns_all?(user.id, [own.id, foreign.id + 1_000_000])
    end

    test "accepts an owned venue's id given as a string" do
      venue = insert(:venue)

      assert Venues.owns_all?(venue.user_id, [to_string(venue.id)])
    end

    test "is false for an id that is not a valid id" do
      venue = insert(:venue)

      refute Venues.owns_all?(venue.user_id, ["abc"])
      refute Venues.owns_all?(venue.user_id, [venue.id, "99999999999999999999"])
      refute Venues.owns_all?(venue.user_id, [venue.id, 99_999_999_999_999_999_999])
    end
  end

  describe "to_choice/1" do
    test "is the venue's id, name and description" do
      venue = insert(:venue, name: "Studio", description: "Old Street 1")

      assert Venues.to_choice(venue) == %{
               id: venue.id,
               name: "Studio",
               description: "Old Street 1"
             }
    end
  end

  describe "display/1" do
    test "is the name alone without a description" do
      assert Venues.display(%{name: "Studio", description: nil}) == "Studio"
      assert Venues.display(%{name: "Studio", description: "  \n "}) == "Studio"
    end

    test "folds a multi-line description onto one line" do
      venue = %{name: "Berlin office", description: "Friedrichstrasse 1\r\n\n  3rd floor\n"}

      assert Venues.display(venue) == "Berlin office (Friedrichstrasse 1, 3rd floor)"
    end
  end

  # Writes the `locations` jsonb as given, bypassing the embedded schema, to
  # stand in for rows an older or forged write left behind.
  defp store_raw_locations(meeting_type, locations) do
    Repo.query!("UPDATE meeting_types SET locations = $1::jsonb[] WHERE id = $2", [
      locations,
      meeting_type.id
    ])
  end
end
