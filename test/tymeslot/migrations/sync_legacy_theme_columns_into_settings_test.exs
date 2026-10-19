defmodule Tymeslot.Migrations.SyncLegacyThemeColumnsIntoSettingsTest do
  @moduledoc """
  Value-correctness regression for
  `20261014084423_sync_legacy_theme_columns_into_settings`, whose trigger
  carries writes the previous release makes to the legacy option columns
  into `settings` while a deploy has both releases running.

  The decisive properties: a row the previous release inserts gets the
  `settings` the settings migration's backfill would have given it; an
  update it makes reaches `settings` for exactly the columns it changed, so
  stale columns never overwrite a newer choice; and the current release's
  own writes pass through untouched.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :themes

  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner
  alias Tymeslot.ThemeCustomizations

  @settings_version 20_260_929_081_519
  @version 20_261_014_084_423

  @columns [
    color_scheme: "custom",
    custom_palette_seed: "#AB34CD",
    background_type: "video",
    background_value: "custom",
    background_image_path: nil,
    background_video_path: "1/2/backgrounds/clip.mp4"
  ]

  @expected_settings %{
    "color_scheme" => "custom",
    "custom_palette_seed" => "#AB34CD",
    "background_type" => "video",
    "background_value" => "custom",
    "background_video_path" => "1/2/backgrounds/clip.mp4"
  }

  defp insert_legacy_row!(profile_id, theme_id, columns) do
    {names, values} = Enum.unzip(columns)
    names = Enum.map_join(names, ", ", &Atom.to_string/1)
    params = Enum.map_join(1..length(values), ", ", &"$#{&1 + 2}")

    Repo.query!(
      """
      INSERT INTO theme_customizations (profile_id, theme_id, #{names}, inserted_at, updated_at)
      VALUES ($1, $2, #{params}, now(), now())
      """,
      [profile_id, theme_id | values]
    )
  end

  # The UPDATE the previous release makes: only the columns it changed.
  defp update_columns!(id, columns) do
    sets =
      columns
      |> Enum.with_index(2)
      |> Enum.map_join(", ", fn {{name, _value}, index} -> "#{name} = $#{index}" end)

    Repo.query!("UPDATE theme_customizations SET #{sets} WHERE id = $1", [
      id | Keyword.values(columns)
    ])
  end

  defp settings(profile_id, theme_id) do
    %{rows: [[settings]]} =
      Repo.query!(
        "SELECT settings FROM theme_customizations WHERE profile_id = $1 AND theme_id = $2",
        [profile_id, theme_id]
      )

    settings
  end

  defp settings_by_id(id) do
    %{rows: [[settings]]} =
      Repo.query!("SELECT settings FROM theme_customizations WHERE id = $1", [id])

    settings
  end

  # The test database already carries the trigger as it was when it was
  # migrated; running the migration again installs the one in the file.
  setup do
    MigrationRunner.rerun!(@version)
    :ok
  end

  defp trigger_count do
    %{rows: [[count]]} =
      Repo.query!("""
      SELECT count(*) FROM pg_trigger
      WHERE tgname = 'theme_customizations_settings_from_legacy_columns'
      """)

    count
  end

  test "a row inserted with no settings, at any point of the upgrade, gets what the backfill gives" do
    [before, between, after_both] = for _n <- 1..3, do: insert(:profile)

    MigrationRunner.down!(@version)
    MigrationRunner.down!(@settings_version)
    insert_legacy_row!(before.id, "2", @columns)

    MigrationRunner.up!(@settings_version)
    insert_legacy_row!(between.id, "2", @columns)
    assert settings(between.id, "2") == nil

    MigrationRunner.up!(@version)
    insert_legacy_row!(after_both.id, "2", @columns)

    # Backfilled by the settings migration, by this one's follow-up backfill,
    # and by the trigger: one mapping, three paths.
    assert settings(before.id, "2") == @expected_settings
    assert settings(between.id, "2") == @expected_settings
    assert settings(after_both.id, "2") == @expected_settings
  end

  test "an update to the columns alone carries exactly the changed columns into settings" do
    # Created by the current release, so its columns hold only their
    # defaults (the stale view the previous release loads).
    customization =
      insert(:theme_customization,
        theme_id: "1",
        color_scheme: "ocean",
        background_type: "gradient",
        background_value: "gradient_2"
      )

    update_columns!(customization.id, color_scheme: "rose")

    assert settings_by_id(customization.id) == %{
             "color_scheme" => "rose",
             "background_type" => "gradient",
             "background_value" => "gradient_2"
           }

    update_columns!(customization.id,
      background_type: "image",
      background_value: "custom",
      background_image_path: "1/1/backgrounds/photo.webp"
    )

    assert settings_by_id(customization.id) == %{
             "color_scheme" => "rose",
             "background_type" => "image",
             "background_value" => "custom",
             "background_image_path" => "1/1/backgrounds/photo.webp"
           }

    # A cleared column clears its key.
    update_columns!(customization.id,
      background_type: "gradient",
      background_value: "gradient_3",
      background_image_path: nil
    )

    assert settings_by_id(customization.id) == %{
             "color_scheme" => "rose",
             "background_type" => "gradient",
             "background_value" => "gradient_3"
           }
  end

  test "the current release's own writes pass through untouched" do
    customization = insert(:theme_customization, theme_id: "1", color_scheme: "ocean")

    {:ok, updated} =
      ThemeCustomizations.upsert_theme_customization(
        customization.profile_id,
        customization.theme_id,
        %{
          "color_scheme" => "forest"
        }
      )

    assert updated.settings["color_scheme"] == "forest"
    assert settings_by_id(customization.id) == updated.settings
  end

  test "rolling back removes the trigger, and running it again restores it" do
    profile = insert(:profile)

    MigrationRunner.down!(@version)
    assert trigger_count() == 0

    insert_legacy_row!(profile.id, "1", color_scheme: "sunset")
    assert settings(profile.id, "1") == nil

    MigrationRunner.up!(@version)
    MigrationRunner.replay!(@version)

    assert trigger_count() == 1

    assert settings(profile.id, "1") == %{
             "color_scheme" => "sunset",
             "background_type" => "gradient"
           }
  end
end
