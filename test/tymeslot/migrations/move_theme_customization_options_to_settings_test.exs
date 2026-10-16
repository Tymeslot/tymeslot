defmodule Tymeslot.Migrations.MoveThemeCustomizationOptionsToSettingsTest do
  @moduledoc """
  Value-correctness regression for
  `20260929081519_move_theme_customization_options_to_settings`, which copies
  each theme customisation's option columns into the `settings` map the
  schema now reads, and keeps the columns for a later release to drop.

  The decisive properties are that **no stored option is lost** in either
  direction and that **the previous release still finds its columns**: the
  schema reads only `settings`, so a row left unfilled would load with no
  customisation at all; the previous release reads only the columns, so they
  must survive the upgrade untouched, and `down/0` must carry any write made
  since the upgrade back into them.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :themes

  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_929_081_519
  # The later sync migration's trigger writes `settings`, which `down/0`
  # here removes, so it comes off first, as it does in a real rollback.
  @sync_version 20_261_014_084_423

  defp roll_back! do
    MigrationRunner.down!(@sync_version)
    MigrationRunner.down!(@version)
  end

  defp insert_legacy_row(profile_id, theme_id, columns) do
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

  defp settings(profile_id, theme_id) do
    %{rows: [[settings]]} =
      Repo.query!(
        "SELECT settings FROM theme_customizations WHERE profile_id = $1 AND theme_id = $2",
        [profile_id, theme_id]
      )

    settings
  end

  defp columns(profile_id, theme_id) do
    %{rows: [row], columns: names} =
      Repo.query!(
        """
        SELECT color_scheme, custom_palette_seed, background_type, background_value,
               background_image_path, background_video_path
        FROM theme_customizations WHERE profile_id = $1 AND theme_id = $2
        """,
        [profile_id, theme_id]
      )

    names |> Enum.zip(row) |> Map.new()
  end

  @all_option_columns ~w(background_image_path background_type background_value
                          background_video_path color_scheme custom_palette_seed)

  defp option_columns do
    %{rows: rows} =
      Repo.query!("""
      SELECT column_name FROM information_schema.columns
      WHERE table_schema = current_schema() AND table_name = 'theme_customizations'
        AND column_name IN ('color_scheme', 'custom_palette_seed', 'background_type',
                            'background_value', 'background_image_path', 'background_video_path')
      """)

    rows |> List.flatten() |> Enum.sort()
  end

  test "every option column is copied into settings, leaving out the null ones" do
    profile = insert(:profile)
    roll_back!()

    insert_legacy_row(profile.id, "1",
      color_scheme: "sunset",
      custom_palette_seed: "#112233",
      background_type: "image",
      background_value: "custom",
      background_image_path: "1/1/backgrounds/photo.webp"
    )

    insert_legacy_row(profile.id, "2", background_value: nil)

    MigrationRunner.up!(@version)

    assert settings(profile.id, "1") == %{
             "color_scheme" => "sunset",
             "custom_palette_seed" => "#112233",
             "background_type" => "image",
             "background_value" => "custom",
             "background_image_path" => "1/1/backgrounds/photo.webp"
           }

    # The columns' own defaults are copied like any other value.
    assert settings(profile.id, "2") == %{
             "color_scheme" => "default",
             "background_type" => "gradient"
           }

    # The previous release still reads its columns, unchanged.
    assert option_columns() == @all_option_columns

    assert columns(profile.id, "1") == %{
             "color_scheme" => "sunset",
             "custom_palette_seed" => "#112233",
             "background_type" => "image",
             "background_value" => "custom",
             "background_image_path" => "1/1/backgrounds/photo.webp",
             "background_video_path" => nil
           }
  end

  test "a rollback carries writes made since the upgrade back into the columns" do
    customization =
      insert(:theme_customization,
        theme_id: "2",
        color_scheme: "ocean",
        background_type: "video",
        background_value: "custom",
        background_video_path: "1/2/backgrounds/clip.mp4"
      )

    roll_back!()

    assert columns(customization.profile_id, "2") == %{
             "color_scheme" => "ocean",
             "custom_palette_seed" => nil,
             "background_type" => "video",
             "background_value" => "custom",
             "background_image_path" => nil,
             "background_video_path" => "1/2/backgrounds/clip.mp4"
           }

    MigrationRunner.up!(@version)

    assert settings(customization.profile_id, "2") == customization.settings
  end

  test "running it again leaves settings written since the first run alone" do
    customization = insert(:theme_customization, theme_id: "1", color_scheme: "forest")

    MigrationRunner.replay!(@version)

    assert settings(customization.profile_id, "1")["color_scheme"] == "forest"
    assert option_columns() == @all_option_columns
  end

  test "a rollback restores the columns on a database that no longer has them" do
    customization =
      insert(:theme_customization,
        theme_id: "1",
        color_scheme: "forest",
        background_value: "gradient_2"
      )

    Repo.query!("""
    ALTER TABLE theme_customizations
      DROP COLUMN color_scheme, DROP COLUMN custom_palette_seed, DROP COLUMN background_type,
      DROP COLUMN background_value, DROP COLUMN background_image_path,
      DROP COLUMN background_video_path
    """)

    roll_back!()

    assert %{"color_scheme" => "forest", "background_value" => "gradient_2"} =
             columns(customization.profile_id, "1")

    MigrationRunner.up!(@version)

    assert option_columns() == @all_option_columns
  end
end
