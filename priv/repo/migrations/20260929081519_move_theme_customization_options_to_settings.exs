defmodule Tymeslot.Repo.Migrations.MoveThemeCustomizationOptionsToSettings do
  @moduledoc """
  A theme customisation's options move from one column each into a single
  `settings` map, whose keys are whatever the theme's customisation spec
  declares, so a theme with a different option set needs no migration of its
  own.

  This is the expand half of an expand/contract change. Every row's
  `color_scheme`, `custom_palette_seed` and `background_*` columns are copied
  into `settings`, leaving out the null ones, but the columns and their two
  indexes stay: an installation that goes back to the previous release
  without running `down/0` still finds the columns it reads, so its booking
  pages keep working (with the options as they were at the upgrade). A later
  release drops them. Only rows whose `settings` is still null are filled,
  and every step is conditional, so the migration is safe to run again.

  `down/0` refills the columns from `settings`, so a rollback keeps every
  option saved since the upgrade. It restores the columns and indexes first
  when they are missing, which only a database that ran an earlier draft of
  this migration can be.
  """
  use Ecto.Migration

  # The schema reads only `settings`, so a row left unfilled would load with
  # no customisation at all; the backfill is the point of the migration. The
  # columns' constant defaults in `down/0` are their original ones, which
  # PostgreSQL adds without rewriting the table, and `down/0` only adds them
  # (and the indexes) where they are missing; it removes only `settings`.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # excellent_migrations:safety-assured-for-this-file operation_update
  # excellent_migrations:safety-assured-for-this-file column_removed
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file column_added_with_default

  @option_columns ~w(color_scheme custom_palette_seed background_type background_value
                     background_image_path background_video_path)

  def up do
    alter table(:theme_customizations) do
      add_if_not_exists(:settings, :map)
    end

    if columns_present?() do
      execute("""
      UPDATE theme_customizations
      SET settings = jsonb_strip_nulls(
        jsonb_build_object(
          'color_scheme', color_scheme,
          'custom_palette_seed', custom_palette_seed,
          'background_type', background_type,
          'background_value', background_value,
          'background_image_path', background_image_path,
          'background_video_path', background_video_path
        )
      )
      WHERE settings IS NULL
      """)
    end
  end

  def down do
    alter table(:theme_customizations) do
      add_if_not_exists(:color_scheme, :string, null: false, default: "default")
      add_if_not_exists(:custom_palette_seed, :string)
      add_if_not_exists(:background_type, :string, null: false, default: "gradient")
      add_if_not_exists(:background_value, :text)
      add_if_not_exists(:background_image_path, :string)
      add_if_not_exists(:background_video_path, :string)
    end

    execute("""
    UPDATE theme_customizations
    SET color_scheme = COALESCE(settings ->> 'color_scheme', 'default'),
        custom_palette_seed = settings ->> 'custom_palette_seed',
        background_type = COALESCE(settings ->> 'background_type', 'gradient'),
        background_value = settings ->> 'background_value',
        background_image_path = settings ->> 'background_image_path',
        background_video_path = settings ->> 'background_video_path'
    WHERE settings IS NOT NULL
    """)

    create_if_not_exists(index(:theme_customizations, [:color_scheme]))
    create_if_not_exists(index(:theme_customizations, [:background_type]))

    alter table(:theme_customizations) do
      remove_if_exists(:settings, :map)
    end
  end

  # A database that ran an earlier draft of this migration has no columns
  # left to copy, and the UPDATE naming them would fail.
  defp columns_present? do
    flush()

    %{rows: [[count]]} =
      repo().query!(
        """
        SELECT count(*) FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = 'theme_customizations'
          AND column_name = ANY($1)
        """,
        [@option_columns]
      )

    count == length(@option_columns)
  end
end
