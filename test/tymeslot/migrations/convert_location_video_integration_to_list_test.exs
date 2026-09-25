defmodule Tymeslot.Migrations.ConvertLocationVideoIntegrationToListTest do
  @moduledoc """
  Value-correctness regression for
  `20260923090451_convert_location_video_integration_to_list`, which rewrites
  every stored location from the single `video_integration_id` key to the
  `video_integration_ids` list a video location now carries.

  The rows are put into the old shape with raw SQL, because the schema can no
  longer write it, and the migration that ships is then replayed over them.

  The decisive property is that **no video location loses its provider**: the
  schema reads only the new key, so a location left in the old shape would
  load as a video option with nothing to create a room on.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :meeting_types

  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_923_090_451

  defp put_raw_locations(name, locations) do
    Repo.query!(
      "UPDATE meeting_types SET locations = $2::jsonb[] WHERE name = $1",
      [name, locations]
    )
  end

  defp locations(name) do
    %{rows: [[locations]]} =
      Repo.query!("SELECT locations FROM meeting_types WHERE name = $1", [name])

    locations
  end

  test "a video location's single integration becomes a one-element list" do
    insert(:meeting_type, name: "Video Consultation")

    put_raw_locations("Video Consultation", [
      %{"id" => "loc-office", "kind" => "in_person", "label" => "Office", "position" => 0},
      %{
        "id" => "loc-zoom",
        "kind" => "video",
        "label" => "Zoom",
        "video_integration_id" => 7,
        "position" => 1
      }
    ])

    MigrationRunner.replay!(@version)

    assert [office, zoom] = locations("Video Consultation")

    assert office == %{
             "id" => "loc-office",
             "kind" => "in_person",
             "label" => "Office",
             "position" => 0
           }

    assert zoom["video_integration_ids"] == [7]
    refute Map.has_key?(zoom, "video_integration_id")
    assert zoom["label"] == "Zoom"
    assert zoom["position"] == 1
  end

  test "a location whose integration key is null becomes an empty list" do
    insert(:meeting_type, name: "Blank")

    put_raw_locations("Blank", [
      %{
        "id" => "loc-1",
        "kind" => "in_person",
        "label" => "Office",
        "video_integration_id" => nil
      }
    ])

    MigrationRunner.replay!(@version)

    assert [%{"video_integration_ids" => []} = location] = locations("Blank")
    refute Map.has_key?(location, "video_integration_id")
  end

  test "a row already in the new shape is left exactly as it was" do
    insert(:meeting_type, name: "Converted")

    converted = [
      %{"id" => "loc-v", "kind" => "video", "label" => "Video", "video_integration_ids" => [7, 9]}
    ]

    put_raw_locations("Converted", converted)

    MigrationRunner.replay!(@version)

    assert locations("Converted") == converted
  end

  test "rolling back keeps a location's first provider under the old key" do
    insert(:meeting_type, name: "Rollback")

    put_raw_locations("Rollback", [
      %{"id" => "loc-v", "kind" => "video", "label" => "Video", "video_integration_ids" => [9, 7]}
    ])

    MigrationRunner.down!(@version)

    assert [%{"video_integration_id" => 9} = location] = locations("Rollback")
    refute Map.has_key?(location, "video_integration_ids")
  end
end
