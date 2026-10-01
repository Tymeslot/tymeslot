defmodule Tymeslot.MeetingTypes.FormVenueOwnershipTest do
  @moduledoc """
  A form-driven meeting-type write refuses an in-person location listing a
  venue the host does not own, the way it refuses a foreign video
  integration.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :meeting_types

  alias Tymeslot.MeetingTypes

  describe "venue ownership" do
    defp in_person_params(venue_ids) do
      %{
        "name" => "Office Visit",
        "duration" => "30",
        "description" => "",
        "is_active" => "true",
        "locations" => [
          %{
            "kind" => "in_person",
            "label" => "Our office",
            "venue_ids" => venue_ids,
            "position" => "0"
          }
        ]
      }
    end

    test "accepts an in-person location listing the host's own venues" do
      user = insert(:user)
      venue = insert(:venue, user: user)

      assert {:ok, meeting_type} =
               MeetingTypes.create_meeting_type_from_form(
                 user.id,
                 in_person_params([to_string(venue.id)]),
                 %{selected_icon: "hero-clock"}
               )

      assert [%{venue_ids: [venue_id]}] = meeting_type.locations
      assert venue_id == venue.id
    end

    test "accepts an in-person location listing no venues" do
      user = insert(:user)

      assert {:ok, meeting_type} =
               MeetingTypes.create_meeting_type_from_form(user.id, in_person_params([]), %{
                 selected_icon: "hero-clock"
               })

      assert [%{venue_ids: []}] = meeting_type.locations
    end

    test "rejects a venue belonging to another user" do
      user = insert(:user)
      foreign = insert(:venue)

      assert {:error, :invalid_venue} =
               MeetingTypes.create_meeting_type_from_form(
                 user.id,
                 in_person_params([to_string(foreign.id)]),
                 %{selected_icon: "hero-clock"}
               )
    end

    test "rejects a venue id that is not a number" do
      user = insert(:user)

      assert {:error, :invalid_venue} =
               MeetingTypes.create_meeting_type_from_form(
                 user.id,
                 in_person_params(["office"]),
                 %{
                   selected_icon: "hero-clock"
                 }
               )
    end
  end
end
