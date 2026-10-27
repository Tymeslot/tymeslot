defmodule Tymeslot.Repo.Migrations.DropRetiredThemeCustomizationColumns do
  @moduledoc """
  The contract half of two expand/contract changes to theme customisations.

  `20260929081519_move_theme_customization_options_to_settings` copied the
  option columns (`color_scheme`, `custom_palette_seed` and the four
  `background_*` columns) into the `settings` map, and
  `20261008094224_add_video_processing_status_to_theme_customizations`
  copied `video_processing` into `video_processing_status`. Both kept the
  old columns, and `20261014084423_sync_legacy_theme_columns_into_settings`
  added a trigger carrying a previous release's writes to them into
  `settings`, so that going back a release without `down/0` stayed safe.
  Nothing reads the columns any more, and both expand releases have shipped,
  so this drops them: the trigger and its function first, since they name
  the columns, then the two indexes and the seven columns.

  Before the drop both backfills run once more, for any row they never
  reached. Each fills only a map that is still unfilled (`settings` null,
  `video_processing_status` empty): a row created or edited since the
  upgrade never had its columns written, so they hold stale defaults, and
  copying them over a filled map would undo every change made since.

  Going back to a release older than v1.26.0 now needs a database restore.
  `down/0` restores the columns, refilled from the maps, with their indexes
  and the trigger as `20261014084423` defines it, for a rollback to a
  release that still has the sync migration.
  """
  use Ecto.Migration

  # The backfills are the reason the drop is safe, so they are raw SQL
  # updates by design; they touch only rows left unfilled, which after the
  # earlier migrations are at most the handful written during a deploy
  # window. The columns are dropped deliberately: nothing in either repo has
  # read them since v1.26.0, and every release since has shipped with them
  # unused. `down/0` re-adds `color_scheme` and `background_type` with their
  # original constant defaults, which PostgreSQL adds without rewriting the
  # table, and rebuilds the two small indexes the expand migration kept.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # excellent_migrations:safety-assured-for-this-file operation_update
  # excellent_migrations:safety-assured-for-this-file column_removed
  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently

  @option_columns ~w(color_scheme custom_palette_seed background_type background_value
                     background_image_path background_video_path)

  # The sync trigger and its function share the name.
  @trigger "theme_customizations_settings_from_legacy_columns"

  def up do
    execute("DROP TRIGGER IF EXISTS #{@trigger} ON theme_customizations")
    execute("DROP FUNCTION IF EXISTS #{@trigger}()")

    if column_present?("color_scheme") do
      execute("""
      UPDATE theme_customizations
      SET settings = #{legacy_settings("")}
      WHERE settings IS NULL
      """)
    end

    if column_present?("video_processing") do
      execute("""
      UPDATE theme_customizations
      SET video_processing_status = jsonb_build_object('background_video_path', video_processing)
      WHERE video_processing IS NOT NULL
        AND video_processing_status = '{}'::jsonb
      """)
    end

    drop_if_exists(index(:theme_customizations, [:color_scheme]))
    drop_if_exists(index(:theme_customizations, [:background_type]))

    alter table(:theme_customizations) do
      remove_if_exists(:color_scheme, :string)
      remove_if_exists(:custom_palette_seed, :string)
      remove_if_exists(:background_type, :string)
      remove_if_exists(:background_value, :text)
      remove_if_exists(:background_image_path, :string)
      remove_if_exists(:background_video_path, :string)
      remove_if_exists(:video_processing, :string)
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
      add_if_not_exists(:video_processing, :string)
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

    execute("""
    UPDATE theme_customizations
    SET video_processing = video_processing_status ->> 'background_video_path'
    WHERE video_processing_status ? 'background_video_path'
    """)

    create_if_not_exists(index(:theme_customizations, [:color_scheme]))
    create_if_not_exists(index(:theme_customizations, [:background_type]))

    execute("""
    CREATE OR REPLACE FUNCTION #{@trigger}() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.settings IS NULL THEN
        NEW.settings := #{legacy_settings("NEW.")};
      ELSIF TG_OP = 'UPDATE' THEN
    #{Enum.map_join(@option_columns, &copy_changed_column/1)}
      END IF;
      RETURN NEW;
    END
    $$
    """)

    execute("DROP TRIGGER IF EXISTS #{@trigger} ON theme_customizations")

    execute("""
    CREATE TRIGGER #{@trigger}
    BEFORE INSERT OR UPDATE ON theme_customizations
    FOR EACH ROW EXECUTE FUNCTION #{@trigger}()
    """)
  end

  # Every option column under its own name, the null ones left out: the
  # object the expand migration's backfill and the sync trigger build.
  defp legacy_settings(prefix) do
    pairs = Enum.map_join(@option_columns, ", ", &"'#{&1}', #{prefix}#{&1}")
    "jsonb_strip_nulls(jsonb_build_object(#{pairs}))"
  end

  # One column an update changed, carried into its key, as the sync trigger
  # does it.
  defp copy_changed_column(column) do
    """
          IF NEW.#{column} IS DISTINCT FROM OLD.#{column} THEN
            NEW.settings := (NEW.settings - '#{column}')
              || jsonb_strip_nulls(jsonb_build_object('#{column}', NEW.#{column}));
          END IF;
    """
  end

  # A rerun after the columns are gone has nothing to backfill from, and an
  # UPDATE naming them would fail.
  defp column_present?(column) do
    flush()

    %{rows: [[count]]} =
      repo().query!(
        """
        SELECT count(*) FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = 'theme_customizations'
          AND column_name = $1
        """,
        [column]
      )

    count == 1
  end
end
