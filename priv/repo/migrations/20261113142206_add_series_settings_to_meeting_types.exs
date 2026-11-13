defmodule Tymeslot.Repo.Migrations.AddSeriesSettingsToMeetingTypes do
  @moduledoc """
  Adds the series settings of a meeting type: whether it is booked as a
  series, the rhythm of a recurring one, and the allowed number of sessions.

  Existing rows get `series_mode` NULL (not a series type), `series_interval`
  1 and `series_required` true, so the check holds for them without a
  backfill. It is added `NOT VALID` and then validated, a
  pattern kept for its habit rather than its lock behaviour: the migration
  runs in one DDL transaction, so the lock is held throughout. `meeting_types`
  is small and the new columns are empty, so the scan is trivial. The tests are wrapped in `COALESCE(..., false)` because a CHECK passes on NULL,
  which would let a series type with no limits or no frequency through.
  """

  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # excellent_migrations:safety-assured-for-this-file column_removed
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  #
  # The defaults are constants, which PostgreSQL 11 and later apply without
  # rewriting the table. The raw statement is the VALIDATE step that follows
  # the NOT VALID constraint; Ecto has no builder for it.

  def up do
    alter table(:meeting_types) do
      add_if_not_exists(:series_mode, :string)
      add_if_not_exists(:series_frequency, :string)
      add_if_not_exists(:series_interval, :integer, default: 1, null: false)
      add_if_not_exists(:series_min_occurrences, :integer)
      add_if_not_exists(:series_max_occurrences, :integer)
      add_if_not_exists(:series_required, :boolean, default: true, null: false)
    end

    execute("ALTER TABLE meeting_types DROP CONSTRAINT IF EXISTS meeting_types_series_check")

    create(
      constraint(:meeting_types, :meeting_types_series_check,
        check: """
        series_mode IS NULL OR (
          series_mode IN ('recurring', 'flexible')
          AND COALESCE(
            series_min_occurrences BETWEEN 2 AND 26
            AND series_max_occurrences BETWEEN series_min_occurrences AND 26,
            false
          )
          AND (
            series_mode = 'flexible'
            OR COALESCE(
              series_frequency IN ('daily', 'weekly', 'monthly')
              AND series_interval BETWEEN 1 AND 4,
              false
            )
          )
        )
        """,
        validate: false
      )
    )

    execute("ALTER TABLE meeting_types VALIDATE CONSTRAINT meeting_types_series_check")
  end

  def down do
    execute("ALTER TABLE meeting_types DROP CONSTRAINT IF EXISTS meeting_types_series_check")

    alter table(:meeting_types) do
      remove_if_exists(:series_required, :boolean)
      remove_if_exists(:series_max_occurrences, :integer)
      remove_if_exists(:series_min_occurrences, :integer)
      remove_if_exists(:series_interval, :integer)
      remove_if_exists(:series_frequency, :string)
      remove_if_exists(:series_mode, :string)
    end
  end
end
