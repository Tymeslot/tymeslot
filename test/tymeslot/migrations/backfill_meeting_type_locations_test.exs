defmodule Tymeslot.Migrations.BackfillMeetingTypeLocationsTest do
  @moduledoc """
  Value-correctness regression for
  `20260903113518_add_locations_to_meeting_types`, which gives every existing
  meeting type the single-entry location list that means exactly what its
  `allow_video` / `video_integration_id` pair already meant.

  The migration is driven directly rather than reimplemented: `down` drops
  the column, putting the rows back in the pre-migration shape, and `up`
  re-adds and backfills it, so the assertions are about the SQL that ships.

  The decisive property is that **no row is left without a location**. Every
  reader of the list treats an empty one as "fall back to the old fields",
  which works but leaves the host's editor showing a location they never
  authored, so the backfill is what makes the list the honest source of truth.

  Runs non-async because it drops and re-adds a live column for the duration
  of the test; the sandbox rolls the DDL back with everything else.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :meeting_types

  alias Ecto.UUID
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_903_113_518

  defp locations(name) do
    %{rows: [[locations]]} =
      Repo.query!("SELECT locations FROM meeting_types WHERE name = $1", [name])

    locations
  end

  defp column_exists?(column) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM information_schema.columns
        WHERE table_name = 'meeting_types' AND column_name = $1
        """,
        [column]
      )

    count == 1
  end

  test "a video meeting type becomes one video location on the integration it named" do
    user = insert(:user)
    integration = insert(:video_integration, user: user, name: "Team Room", is_active: true)

    insert(:meeting_type,
      user: user,
      name: "Video Consultation",
      allow_video: true,
      video_integration: integration
    )

    MigrationRunner.rerun!(@version)

    assert [location] = locations("Video Consultation")
    assert location["kind"] == "video"
    assert location["label"] == "Team Room"
    assert location["video_integration_id"] == integration.id
    assert location["position"] == 0
    assert location["collect_from_guest"] == false
    assert {:ok, _uuid} = UUID.cast(location["id"])
  end

  test "a non-video meeting type becomes one in-person location" do
    user = insert(:user)
    insert(:meeting_type, user: user, name: "Coffee Chat", allow_video: false)

    MigrationRunner.rerun!(@version)

    assert [%{"kind" => "in_person", "label" => "In person", "position" => 0}] =
             locations("Coffee Chat")
  end

  test "a video meeting type whose integration is gone falls back to in-person" do
    user = insert(:user)

    # The pre-migration state a deleted integration leaves behind: the flag
    # says video, the foreign key has been nulled, and there is no provider
    # left to offer. Written directly because the changeset refuses it.
    insert(:meeting_type, user: user, name: "Orphaned Video", allow_video: false)

    Repo.query!(
      "UPDATE meeting_types SET allow_video = true, video_integration_id = NULL WHERE name = $1",
      ["Orphaned Video"]
    )

    MigrationRunner.rerun!(@version)

    assert [%{"kind" => "in_person"}] = locations("Orphaned Video")
  end

  test "every row ends up with exactly one location, whatever shape it was in" do
    user = insert(:user)
    integration = insert(:video_integration, user: user, is_active: true)

    insert(:meeting_type, user: user, name: "A", allow_video: false)

    insert(:meeting_type,
      user: user,
      name: "B",
      allow_video: true,
      video_integration: integration
    )

    insert(:meeting_type, user: user, name: "C", allow_video: false, is_archived: true)

    MigrationRunner.rerun!(@version)

    %{rows: rows} =
      Repo.query!("SELECT name, coalesce(array_length(locations, 1), 0) FROM meeting_types")

    assert rows != []
    assert Enum.reject(rows, fn [_name, count] -> count == 1 end) == []
  end

  test "the column is genuinely absent before the migration runs" do
    MigrationRunner.down!(@version)
    refute column_exists?("locations")

    MigrationRunner.up!(@version)
    assert column_exists?("locations")
  end
end
