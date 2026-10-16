defmodule Tymeslot.Repo.Migrations.SyncLegacyThemeColumnsIntoSettings do
  @moduledoc """
  Keeps a theme customisation's `settings` in step with its legacy option
  columns for as long as both exist, so a write the previous release makes
  after `20260929081519_move_theme_customization_options_to_settings` has
  run is not lost.

  The backfill in that migration copies the columns once. On a deployment
  that migrates while the previous release is still serving (Railway runs
  migrations in the new deployment's start command, before the old one is
  stopped), the previous release goes on writing only the columns:

    * a row it inserts gets no `settings`, which the schema reads as the
      theme's defaults, so the booking page silently loses the choices;
    * a row it updates changes only the columns, so the change never
      reaches `settings` and is gone once the old deployment stops.

  A `BEFORE INSERT OR UPDATE` trigger closes both. A row arriving with no
  `settings` gets them from its columns, exactly as the backfill builds
  them. An update carries each option column it changed into its key, and
  only those: a column the update did not touch may be stale (a row the
  current release created or edited never had its columns written), so
  copying it would overwrite a newer choice. The current release never
  writes the columns, so its own writes pass through untouched. The
  backfill is then run once more, for a row inserted between the two
  migrations.

  The trigger rather than a read-time fallback: the schema no longer maps
  the columns, every read path (direct, preloaded, the demo shim) would need
  the fallback, and none of them could recover an update; the trigger sits
  at the one boundary every write crosses, and needs no application code.
  The reverse direction (a write by the current release reaching the
  columns the previous one reads) is not covered: the previous release then
  shows the options as they were at the upgrade until it stops, which is the
  documented expand-release behaviour.

  The contract release that drops the columns must drop the trigger and its
  function first, after re-running the backfill for any row whose `settings`
  is still null. `down/0` drops the trigger and function only; the settings
  it filled are the ones the backfill would have written.

  Like the backfill, the SQL deliberately restates the column-to-key mapping
  rather than sharing code with the earlier migration, so each migration
  stays self-contained; the migration test asserts the two produce the same
  `settings` for the same row.
  """
  use Ecto.Migration

  # Creating the trigger and the follow-up backfill are raw SQL by nature,
  # and the backfill is the reason the migration exists. It touches only rows
  # whose `settings` is still null, which after the earlier backfill are at
  # most the handful written during the deploy window.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # excellent_migrations:safety-assured-for-this-file operation_update

  @option_columns ~w(color_scheme custom_palette_seed background_type background_value
                     background_image_path background_video_path)

  # The trigger and its function share the name.
  @name "theme_customizations_settings_from_legacy_columns"

  def up do
    if columns_present?() do
      execute("""
      CREATE OR REPLACE FUNCTION #{@name}() RETURNS trigger
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

      execute("DROP TRIGGER IF EXISTS #{@name} ON theme_customizations")

      execute("""
      CREATE TRIGGER #{@name}
      BEFORE INSERT OR UPDATE ON theme_customizations
      FOR EACH ROW EXECUTE FUNCTION #{@name}()
      """)

      execute("""
      UPDATE theme_customizations
      SET settings = #{legacy_settings("")}
      WHERE settings IS NULL
      """)
    end
  end

  def down do
    execute("DROP TRIGGER IF EXISTS #{@name} ON theme_customizations")
    execute("DROP FUNCTION IF EXISTS #{@name}()")
  end

  # The same object the earlier backfill builds: every option column under
  # its own name, the null ones left out.
  defp legacy_settings(prefix) do
    pairs = Enum.map_join(@option_columns, ", ", &"'#{&1}', #{prefix}#{&1}")
    "jsonb_strip_nulls(jsonb_build_object(#{pairs}))"
  end

  # One column the update changed, carried into its key: set to the new
  # value, or removed when the column was cleared.
  defp copy_changed_column(column) do
    """
          IF NEW.#{column} IS DISTINCT FROM OLD.#{column} THEN
            NEW.settings := (NEW.settings - '#{column}')
              || jsonb_strip_nulls(jsonb_build_object('#{column}', NEW.#{column}));
          END IF;
    """
  end

  # A database that ran an earlier draft of the settings migration has no
  # columns left for the previous release to write, so nothing to keep in
  # step, and a trigger naming them would fail on every write.
  defp columns_present? do
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
