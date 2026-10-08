defmodule Tymeslot.Migrations.AddVideoProcessingStatusToThemeCustomizationsTest do
  @moduledoc """
  Value-correctness regression for
  `add_video_processing_status_to_theme_customizations`, which moves each
  theme customisation's one video processing state into a map keyed by the
  asset field it describes, and keeps the old column for a later release to
  drop.

  The decisive properties: **no state is lost in either direction** (every
  row's state lands under `background_video_path`, the one video field there
  has been, and a rollback carries the background video's state back into
  the column the previous release reads), and **running it again changes
  nothing written since**.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :themes

  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_008_094_224

  defp insert_legacy_row(profile_id, theme_id, video_processing) do
    Repo.query!(
      """
      INSERT INTO theme_customizations
        (profile_id, theme_id, settings, video_processing, inserted_at, updated_at)
      VALUES ($1, $2, '{}'::jsonb, $3, now(), now())
      """,
      [profile_id, theme_id, video_processing]
    )
  end

  defp column(profile_id, theme_id, name) do
    %{rows: [[value]]} =
      Repo.query!(
        "SELECT #{name} FROM theme_customizations WHERE profile_id = $1 AND theme_id = $2",
        [profile_id, theme_id]
      )

    value
  end

  defp status_column? do
    %{rows: [[count]]} =
      Repo.query!("""
      SELECT count(*) FROM information_schema.columns
      WHERE table_schema = current_schema() AND table_name = 'theme_customizations'
        AND column_name = 'video_processing_status'
      """)

    count == 1
  end

  test "every row's state moves under the background video, and a row without one stays empty" do
    profile = insert(:profile)
    MigrationRunner.down!(@version)
    refute status_column?()

    insert_legacy_row(profile.id, "1", "completed")
    insert_legacy_row(profile.id, "2", nil)

    MigrationRunner.up!(@version)

    assert column(profile.id, "1", "video_processing_status") ==
             %{"background_video_path" => "completed"}

    assert column(profile.id, "2", "video_processing_status") == %{}

    # The previous release still reads its column, unchanged.
    assert column(profile.id, "1", "video_processing") == "completed"
  end

  test "running it again leaves the states written since the first run alone" do
    profile = insert(:profile)
    insert_legacy_row(profile.id, "1", "pending")

    Repo.query!(
      """
      UPDATE theme_customizations
      SET video_processing_status = '{"background_video_path": "completed", "host_video_path": "pending"}'
      WHERE profile_id = $1
      """,
      [profile.id]
    )

    MigrationRunner.replay!(@version)

    assert column(profile.id, "1", "video_processing_status") == %{
             "background_video_path" => "completed",
             "host_video_path" => "pending"
           }
  end

  test "a rollback carries the background video's state back into the old column" do
    profile = insert(:profile)
    insert_legacy_row(profile.id, "1", "pending")
    insert_legacy_row(profile.id, "2", "failed")

    Repo.query!(
      """
      UPDATE theme_customizations
      SET video_processing_status = '{"background_video_path": "completed"}'
      WHERE profile_id = $1 AND theme_id = '1'
      """,
      [profile.id]
    )

    Repo.query!(
      """
      UPDATE theme_customizations
      SET video_processing_status = '{"host_video_path": "completed"}'
      WHERE profile_id = $1 AND theme_id = '2'
      """,
      [profile.id]
    )

    MigrationRunner.down!(@version)

    refute status_column?()
    assert column(profile.id, "1", "video_processing") == "completed"
    # No background video state to carry back: the column keeps its own.
    assert column(profile.id, "2", "video_processing") == "failed"

    MigrationRunner.up!(@version)
  end
end
