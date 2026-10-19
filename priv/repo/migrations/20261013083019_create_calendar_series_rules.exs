defmodule Tymeslot.Repo.Migrations.CreateCalendarSeriesRules do
  @moduledoc """
  One row per Google or Outlook series an integration's cache holds
  occurrences of: the series' repeat rule and its first start, read from the
  series' master. Both providers list a series as its single occurrences
  only, so the rule is fetched apart from them and copied onto each
  occurrence as it is cached.

  Existing Google and Outlook integrations are then given one full read, so
  the series they already hold fill in on their next sync rather than only
  as their occurrences next change.
  """

  use Ecto.Migration

  # The table is created here, empty, so its reference and indexes lock and
  # validate nothing that already exists.
  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently

  def up do
    create table(:calendar_series_rules) do
      add :calendar_integration_id, references(:calendar_integrations, on_delete: :delete_all),
        null: false

      # Text, as `provider_calendar_events.recurring_event_id` is: provider
      # ids run past 255 bytes.
      add :provider_master_id, :text, null: false
      # Nil once the master was read and found to be gone or not a series,
      # which spares asking again until the read is stale.
      add :rule, :text
      add :master_start, :utc_datetime
      add :fetched_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:calendar_series_rules, [:calendar_integration_id, :provider_master_id])

    # Why these resets are safe: neither deletes anything itself. A Google
    # integration without a sync token makes a full list on its next run, and
    # an Outlook one without a full-sync time makes a fresh delta bootstrap;
    # both upsert the rows they read by the same uids the incremental reads
    # use, so the rows they return are kept and gain their rules. The only
    # rows that go are the ones a full read removes on any day: Google's
    # full list sweeps cached rows it no longer returns, as it does whenever
    # it lists in full. Each reset costs one full read per integration, once.
    # The update touches one small row per integration, so it runs inside the
    # migration's transaction.
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    UPDATE calendar_integrations SET google_sync_token = NULL
    WHERE provider = 'google' AND google_sync_token IS NOT NULL
    """)

    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    UPDATE calendar_integrations SET last_full_sync_at = NULL
    WHERE provider = 'outlook' AND last_full_sync_at IS NOT NULL
    """)
  end

  # The resets are not undone: a sync token or full-sync time cannot be
  # restored, and a missing one only costs a full read.
  def down do
    # Undoes only this migration's own table.
    # excellent_migrations:safety-assured-for-next-line table_dropped
    drop table(:calendar_series_rules)
  end
end
