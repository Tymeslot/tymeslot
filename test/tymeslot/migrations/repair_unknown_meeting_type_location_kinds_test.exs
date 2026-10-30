defmodule Tymeslot.Migrations.RepairUnknownMeetingTypeLocationKindsTest do
  @moduledoc """
  Value-correctness regression for
  `20261029154024_repair_unknown_meeting_type_location_kinds`, which rewrites
  any stored meeting-type location whose `kind` the `Ecto.Enum` would refuse
  to load.

  The decisive property is that **the meeting type loads again** with the
  stray option kept as a `custom` one, and that every known option in the
  same list is left exactly as it was.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :meeting_types

  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_029_154_024

  defp put_raw_locations(id, locations) do
    Repo.query!(
      "UPDATE meeting_types SET locations = $2::jsonb[] WHERE id = $1",
      [id, locations]
    )
  end

  defp raw_locations(id) do
    %{rows: [[locations]]} =
      Repo.query!("SELECT locations FROM meeting_types WHERE id = $1", [id])

    locations
  end

  test "an unknown kind becomes custom, keeping its label and details" do
    meeting_type = insert(:meeting_type)

    office = %{"id" => "loc-office", "kind" => "in_person", "label" => "Office", "position" => 0}

    put_raw_locations(meeting_type.id, [
      office,
      %{
        "id" => "loc-pigeon",
        "kind" => "carrier_pigeon",
        "label" => "By pigeon",
        "details" => "Loft 3",
        "venue_ids" => [4],
        "video_integration_ids" => [7],
        "collect_from_guest" => true,
        "position" => 1
      }
    ])

    assert_raise ArgumentError, fn -> Repo.get!(MeetingTypeSchema, meeting_type.id) end

    MigrationRunner.replay!(@version)

    assert [^office, pigeon] = raw_locations(meeting_type.id)

    assert pigeon == %{
             "id" => "loc-pigeon",
             "kind" => "custom",
             "label" => "By pigeon",
             "details" => "Loft 3",
             "venue_ids" => [],
             "video_integration_ids" => [],
             "collect_from_guest" => false,
             "position" => 1
           }

    assert %{locations: [%{kind: :in_person}, %{kind: :custom, label: "By pigeon"}]} =
             Repo.get!(MeetingTypeSchema, meeting_type.id)
  end

  test "a location without a kind and a clean list are left untouched" do
    clean = insert(:meeting_type)
    kindless = insert(:meeting_type)

    video = %{
      "id" => "loc-zoom",
      "kind" => "video",
      "label" => "Zoom",
      "video_integration_ids" => [7],
      "position" => 0
    }

    no_kind = %{"id" => "loc-x", "kind" => nil, "label" => "Somewhere", "position" => 0}

    put_raw_locations(clean.id, [video])
    put_raw_locations(kindless.id, [no_kind])

    MigrationRunner.replay!(@version)

    assert raw_locations(clean.id) == [video]
    assert raw_locations(kindless.id) == [no_kind]
  end
end
