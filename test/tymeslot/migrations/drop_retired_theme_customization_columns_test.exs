defmodule Tymeslot.Migrations.DropRetiredThemeCustomizationColumnsTest do
  @moduledoc """
  Covers `20261020161429_drop_retired_theme_customization_columns`, the
  contract half that drops the theme customisation columns the `settings`
  and `video_processing_status` maps replaced, with the sync trigger that
  named them.

  The decisive properties are that a row neither backfill reached is filled
  before its columns go, that a map already filled is never overwritten from
  its stale columns, and that `down/0` gives a rollback its columns back with
  the options as the maps hold them.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :themes

  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_020_161_429
  @trigger "theme_customizations_settings_from_legacy_columns"

  @retired_columns ~w(background_image_path background_type background_value
                      background_video_path color_scheme custom_palette_seed video_processing)

  # A row the backfills never reached: its columns written, its maps not.
  # The sync trigger would fill a null `settings` on insert, so it is held
  # off for the insert, as it was for a row written before it existed.
  defp insert_unfilled_row(profile_id, theme_id, columns) do
    {names, values} = Enum.unzip(columns)
    names = Enum.map_join(names, ", ", &Atom.to_string/1)
    params = Enum.map_join(1..length(values), ", ", &"$#{&1 + 2}")

    Repo.query!("ALTER TABLE theme_customizations DISABLE TRIGGER #{@trigger}")

    Repo.query!(
      """
      INSERT INTO theme_customizations (profile_id, theme_id, #{names}, inserted_at, updated_at)
      VALUES ($1, $2, #{params}, now(), now())
      """,
      [profile_id, theme_id | values]
    )

    Repo.query!("ALTER TABLE theme_customizations ENABLE TRIGGER #{@trigger}")
  end

  defp maps(profile_id, theme_id) do
    %{rows: [[settings, status]]} =
      Repo.query!(
        """
        SELECT settings, video_processing_status FROM theme_customizations
        WHERE profile_id = $1 AND theme_id = $2
        """,
        [profile_id, theme_id]
      )

    {settings, status}
  end

  defp retired_columns_present do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT column_name FROM information_schema.columns
        WHERE table_schema = current_schema() AND table_name = 'theme_customizations'
          AND column_name = ANY($1)
        ORDER BY column_name
        """,
        [@retired_columns]
      )

    List.flatten(rows)
  end

  defp count(sql, params) do
    %{rows: [[count]]} = Repo.query!(sql, params)
    count
  end

  defp trigger_count,
    do: count("SELECT count(*) FROM pg_trigger WHERE tgname = $1", [@trigger])

  defp function_count,
    do: count("SELECT count(*) FROM pg_proc WHERE proname = $1", [@trigger])

  defp retired_index_count,
    do:
      count(
        "SELECT count(*) FROM pg_indexes WHERE tablename = 'theme_customizations' AND indexname = ANY($1)",
        [~w(theme_customizations_color_scheme_index theme_customizations_background_type_index)]
      )

  setup do
    MigrationRunner.down!(@version)
    %{profile: insert(:profile)}
  end

  test "fills a row neither backfill reached before dropping its columns", %{profile: profile} do
    insert_unfilled_row(profile.id, "1",
      color_scheme: "sunset",
      background_type: "video",
      background_video_path: "1/1/backgrounds/clip.mp4",
      video_processing: "completed"
    )

    MigrationRunner.up!(@version)

    assert maps(profile.id, "1") ==
             {%{
                "color_scheme" => "sunset",
                "background_type" => "video",
                "background_video_path" => "1/1/backgrounds/clip.mp4"
              }, %{"background_video_path" => "completed"}}
  end

  test "leaves a filled map alone, whatever its stale columns hold", %{profile: profile} do
    # The current release writes only the maps, so the columns of a row it
    # created hold their defaults (and an old processing state here).
    insert_unfilled_row(profile.id, "2",
      color_scheme: "default",
      background_type: "gradient",
      video_processing: "failed",
      settings: %{"color_scheme" => "ocean", "background_type" => "image"},
      video_processing_status: %{"background_image_path" => "processing"}
    )

    MigrationRunner.up!(@version)

    assert maps(profile.id, "2") ==
             {%{"color_scheme" => "ocean", "background_type" => "image"},
              %{"background_image_path" => "processing"}}
  end

  test "drops the trigger, its function, the indexes and the columns", %{profile: profile} do
    assert trigger_count() == 1
    assert function_count() == 1
    assert retired_index_count() == 2
    assert retired_columns_present() == @retired_columns

    MigrationRunner.up!(@version)

    assert trigger_count() == 0
    assert function_count() == 0
    assert retired_index_count() == 0
    assert retired_columns_present() == []

    customization = insert(:theme_customization, profile: profile, theme_id: "1")
    assert customization.id
  end

  test "a rollback restores the columns from the maps, with the trigger",
       %{profile: profile} do
    MigrationRunner.up!(@version)

    insert(:theme_customization,
      profile: profile,
      theme_id: "2",
      color_scheme: "forest",
      background_type: "video",
      background_video_path: "1/2/backgrounds/clip.mp4",
      video_processing_status: %{"background_video_path" => "completed"}
    )

    MigrationRunner.down!(@version)

    %{rows: [row], columns: names} =
      Repo.query!(
        """
        SELECT color_scheme, background_type, background_video_path, video_processing
        FROM theme_customizations WHERE profile_id = $1 AND theme_id = '2'
        """,
        [profile.id]
      )

    assert names |> Enum.zip(row) |> Map.new() == %{
             "color_scheme" => "forest",
             "background_type" => "video",
             "background_video_path" => "1/2/backgrounds/clip.mp4",
             "video_processing" => "completed"
           }

    assert retired_index_count() == 2
    assert trigger_count() == 1

    # The restored trigger carries a previous release's column write into
    # `settings`, as the sync migration's does.
    Repo.query!(
      "UPDATE theme_customizations SET color_scheme = 'sunset' WHERE profile_id = $1 AND theme_id = '2'",
      [profile.id]
    )

    assert {%{"color_scheme" => "sunset"}, _status} = maps(profile.id, "2")
  end
end
