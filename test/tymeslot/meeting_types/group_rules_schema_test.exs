defmodule Tymeslot.MeetingTypes.GroupRulesSchemaTest do
  @moduledoc """
  What a group meeting type (more than one participant per slot) cannot also
  be: a type requiring approval, or one whose location is not fixed in
  advance. Payment's exclusivity is covered in `MeetingTypeSchemaTest`.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :meeting_types
  @moduletag :schema

  alias Tymeslot.MeetingTypes.GroupLocationRule
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  @fixed_location %{kind: "custom", label: "Main hall"}

  defp changeset(attrs) do
    MeetingTypeSchema.changeset(
      %MeetingTypeSchema{},
      Map.merge(%{name: "Workshop", duration_minutes: 60, user_id: 1}, attrs)
    )
  end

  defp group_with_locations(locations),
    do: changeset(%{max_participants: 5, locations: locations})

  describe "approval" do
    test "a group type cannot require approval" do
      cs =
        changeset(%{max_participants: 5, requires_approval: true, locations: [@fixed_location]})

      assert "group bookings cannot require approval" in errors_on(cs).max_participants
    end

    test "turning an approval type into a group type is refused" do
      stored = %MeetingTypeSchema{
        name: "Workshop",
        duration_minutes: 60,
        user_id: 1,
        requires_approval: true,
        max_participants: 1
      }

      cs =
        MeetingTypeSchema.changeset(stored, %{max_participants: 5, locations: [@fixed_location]})

      assert "group bookings cannot require approval" in errors_on(cs).max_participants
    end

    test "a one-to-one type may require approval" do
      assert changeset(%{max_participants: 1, requires_approval: true}).valid?
    end
  end

  describe "location fixed in advance" do
    test "exactly one custom location is accepted" do
      assert group_with_locations([@fixed_location]).valid?
    end

    test "a published phone number is accepted" do
      cs = group_with_locations([%{kind: "phone", label: "Phone", details: "+44 20 7946 0000"}])
      assert cs.valid?
    end

    test "a video call on one provider is accepted" do
      assert group_with_locations([%{kind: "video", label: "Video", video_integration_ids: [7]}]).valid?
    end

    test "an in-person location at one venue is accepted" do
      assert group_with_locations([%{kind: "in_person", label: "Office", venue_ids: [3]}]).valid?
    end

    test "two locations are refused" do
      cs =
        group_with_locations([
          @fixed_location,
          %{kind: "phone", label: "Phone", details: "+44 20 7946 0000"}
        ])

      assert "a group meeting type must offer exactly one location" in errors_on(cs).locations
    end

    test "a choice of video providers is refused" do
      cs = group_with_locations([%{kind: "video", label: "Video", video_integration_ids: [7, 8]}])

      assert "a group meeting type's video call must use exactly one provider" in errors_on(cs).locations
    end

    test "a choice of venues is refused" do
      cs = group_with_locations([%{kind: "in_person", label: "Office", venue_ids: [3, 4]}])

      assert "a group meeting type's in-person location must name exactly one venue" in errors_on(
               cs
             ).locations
    end

    test "an in-person location with the address arranged after booking is refused" do
      cs = group_with_locations([%{kind: "in_person", label: "Office"}])

      assert "a group meeting type's in-person location must name a venue" in errors_on(cs).locations
    end

    test "a phone number collected from each booker is refused" do
      cs = group_with_locations([%{kind: "phone", label: "Phone", collect_from_guest: true}])

      assert "a group meeting type cannot ask each booker for their phone number" in errors_on(cs).locations
    end

    test "a type with no stored list falls back to the in-person option, which is refused" do
      cs = changeset(%{max_participants: 5})

      assert "a group meeting type's in-person location must name a venue" in errors_on(cs).locations
    end

    test "a type with no stored list but a single video integration is accepted" do
      stored = %MeetingTypeSchema{
        name: "Workshop",
        duration_minutes: 60,
        user_id: 1,
        allow_video: true,
        video_integration_id: 7,
        locations: []
      }

      assert MeetingTypeSchema.changeset(stored, %{max_participants: 5}).valid?
    end

    test "one-to-one types may still offer a choice" do
      cs =
        changeset(%{
          max_participants: 1,
          locations: [@fixed_location, %{kind: "in_person", label: "Office", venue_ids: [3, 4]}]
        })

      assert cs.valid?
    end
  end

  describe "GroupLocationRule.check/1" do
    test "an empty list is not a single location" do
      assert {:error, :not_single_location} = GroupLocationRule.check([])
    end
  end
end
