defmodule Tymeslot.Repo.Migrations.RecreateProviderCalendarEvents do
  @moduledoc """
  Migrates the existing `calendar_events` table into `provider_calendar_events`
  with the canonical schema. Preserves all existing rows so self-hosters
  upgrading don't lose their synced cache and hit gaps in the calendar grid
  until the next sync cycle rebuilds it.

  Handles three starting states:

  1. Fresh install — no prior table.
  2. Released main — `calendar_events` exists with legacy columns.
  3. Earlier feature-branch attempt — `provider_calendar_events` already exists
     in some intermediate shape.

  Flow:
  - Rename `calendar_events` → `provider_calendar_events` if needed.
  - Create the table with its mandatory columns (fresh install path).
  - Add all new columns via `add_if_not_exists`.
  - Backfill `summary` from legacy `title`, `provider_calendar_id` from
    legacy `calendar_path`, `provider` from the joined
    `calendar_integrations` row.
  - Upgrade timing columns to microsecond precision.
  - Constrain backfilled columns to `NOT NULL`.
  - Drop legacy columns (`calendar_path`, `title`, `raw_data`).
  - Ensure the full index set is present.
  """

  use Ecto.Migration

  def up do
    # State (2) → state (3): if we're upgrading from released main,
    # rename first so the rest of the migration can operate on one table.
    # PostgreSQL does not rename indexes when a table is renamed, so the
    # legacy `calendar_events_*_index` names survive. We rename or drop
    # them explicitly here so the `create_if_not_exists` block at the
    # bottom matches the existing indexes instead of bloating the table
    # with duplicates.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'calendar_events')
         AND NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'provider_calendar_events') THEN
        ALTER TABLE calendar_events RENAME TO provider_calendar_events;
      END IF;

      IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'calendar_events_calendar_integration_id_uid_index') THEN
        ALTER INDEX calendar_events_calendar_integration_id_uid_index
          RENAME TO provider_calendar_events_calendar_integration_id_uid_index;
      END IF;

      IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'calendar_events_calendar_integration_id_start_at_end_at_index') THEN
        DROP INDEX calendar_events_calendar_integration_id_start_at_end_at_index;
      END IF;

      IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'calendar_events_calendar_integration_id_provider_event_id_index') THEN
        DROP INDEX calendar_events_calendar_integration_id_provider_event_id_index;
      END IF;

      IF EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'calendar_events_pkey') THEN
        ALTER INDEX calendar_events_pkey RENAME TO provider_calendar_events_pkey;
      END IF;
    END $$;
    """)

    # State (1) → state (3): fresh install. Minimal columns only; the
    # `alter` block below adds the rest.
    create_if_not_exists table(:provider_calendar_events) do
      add :uid, :string, null: false

      add :calendar_integration_id,
          references(:calendar_integrations, on_delete: :delete_all),
          null: false

      add :all_day, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    # Add every canonical column. `add_if_not_exists` keeps this idempotent
    # across all three starting states.
    alter table(:provider_calendar_events) do
      add_if_not_exists :provider, :string
      add_if_not_exists :provider_calendar_id, :string
      add_if_not_exists :provider_event_id, :string
      add_if_not_exists :summary, :string
      add_if_not_exists :description, :text
      add_if_not_exists :location, :string
      add_if_not_exists :visibility, :string
      add_if_not_exists :colour, :string
      add_if_not_exists :start_date, :date
      add_if_not_exists :end_date, :date
      add_if_not_exists :start_at, :utc_datetime_usec
      add_if_not_exists :end_at, :utc_datetime_usec
      add_if_not_exists :timezone, :string
      add_if_not_exists :transparency, :string, default: "opaque"
      add_if_not_exists :status, :string, default: "confirmed"
      add_if_not_exists :organiser, :map
      add_if_not_exists :attendees, {:array, :map}, default: []
      add_if_not_exists :recurrence_rule, :string
      add_if_not_exists :recurrence_exceptions, {:array, :date}, default: []
      add_if_not_exists :recurring_event_id, :string
      add_if_not_exists :attachments, {:array, :map}, default: []
      add_if_not_exists :links, {:array, :map}, default: []
      add_if_not_exists :reminders, {:array, :map}, default: []
      add_if_not_exists :etag, :string
      add_if_not_exists :synced_at, :utc_datetime_usec
      add_if_not_exists :provider_updated_at, :utc_datetime_usec
      add_if_not_exists :provider_metadata, :map, default: %{}
      add_if_not_exists :created_by_tymeslot, :boolean, null: false, default: false
    end

    flush()

    # Upgrade timing columns to microsecond precision and drop the legacy
    # NOT NULL constraints on start_at/end_at. The canonical schema models
    # all-day events with `start_date`/`end_date` only, leaving start_at
    # and end_at NULL — the released `calendar_events` table had them
    # NOT NULL, which would reject every all-day row post-migration.
    execute("""
    ALTER TABLE provider_calendar_events
      ALTER COLUMN start_at TYPE timestamp(6) WITHOUT TIME ZONE,
      ALTER COLUMN start_at DROP NOT NULL,
      ALTER COLUMN end_at TYPE timestamp(6) WITHOUT TIME ZONE,
      ALTER COLUMN end_at DROP NOT NULL,
      ALTER COLUMN synced_at TYPE timestamp(6) WITHOUT TIME ZONE
    """)

    # Backfill from legacy columns, conditionally on their presence so the
    # same migration works on fresh installs.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'provider_calendar_events' AND column_name = 'title'
      ) THEN
        EXECUTE 'UPDATE provider_calendar_events SET summary = title WHERE summary IS NULL';
      END IF;

      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'provider_calendar_events' AND column_name = 'calendar_path'
      ) THEN
        EXECUTE 'UPDATE provider_calendar_events SET provider_calendar_id = COALESCE(provider_calendar_id, calendar_path)';
      END IF;
    END $$;
    """)

    # Backfill provider from the joined integration row. Falls back to
    # 'primary' for provider_calendar_id when neither calendar_path nor a
    # prior value was set.
    execute("""
    UPDATE provider_calendar_events cec
    SET provider = COALESCE(cec.provider, ci.provider),
        provider_calendar_id = COALESCE(cec.provider_calendar_id, 'primary')
    FROM calendar_integrations ci
    WHERE cec.calendar_integration_id = ci.id
      AND (cec.provider IS NULL OR cec.provider_calendar_id IS NULL)
    """)

    # Catch-all guards before applying NOT NULL. The JOIN above silently
    # skips any row whose `calendar_integration_id` does not match a
    # live `calendar_integrations` row (orphans from historical FK states
    # or rows with a NULL provider on the joined side). These rows would
    # otherwise abort the ALTER ... SET NOT NULL half-way through,
    # leaving the table in an intermediate state. We default them rather
    # than deleting so no user data is silently dropped.
    execute("UPDATE provider_calendar_events SET provider = 'caldav' WHERE provider IS NULL")

    execute(
      "UPDATE provider_calendar_events SET provider_calendar_id = 'primary' WHERE provider_calendar_id IS NULL"
    )

    # Every row must have a synced_at before NOT NULL is applied.
    # `inserted_at` is NOT NULL for rows created via Ecto, but a final
    # COALESCE to NOW() guards against hand-inserted rows from other tools.
    execute(
      "UPDATE provider_calendar_events SET synced_at = COALESCE(synced_at, inserted_at, NOW()) WHERE synced_at IS NULL"
    )

    # Constrain backfilled columns. transparency/status are NOT NULL with
    # defaults, which handle any row where the column existed as NULL before.
    execute("UPDATE provider_calendar_events SET transparency = 'opaque' WHERE transparency IS NULL")
    execute("UPDATE provider_calendar_events SET status = 'confirmed' WHERE status IS NULL")

    # `status` pre-exists from the legacy `create_calendar_events` migration
    # without a column default, so `add_if_not_exists :status, default: "confirmed"`
    # above is a no-op on upgraded databases. Set the DB-level default
    # explicitly so `Repo.insert_all` (which bypasses Ecto schema defaults)
    # gets 'confirmed' for rows that omit the field.
    execute("""
    ALTER TABLE provider_calendar_events
      ALTER COLUMN status SET DEFAULT 'confirmed',
      ALTER COLUMN transparency SET DEFAULT 'opaque',
      ALTER COLUMN provider SET NOT NULL,
      ALTER COLUMN provider_calendar_id SET NOT NULL,
      ALTER COLUMN synced_at SET NOT NULL,
      ALTER COLUMN transparency SET NOT NULL,
      ALTER COLUMN status SET NOT NULL
    """)

    # Drop legacy columns that have no canonical equivalent. `raw_data`
    # contents are discarded — the canonical schema stores everything in
    # dedicated columns plus `provider_metadata`.
    execute("""
    ALTER TABLE provider_calendar_events
      DROP COLUMN IF EXISTS calendar_path,
      DROP COLUMN IF EXISTS title,
      DROP COLUMN IF EXISTS raw_data
    """)

    # Ensure the full canonical index set is present regardless of start state.
    create_if_not_exists unique_index(:provider_calendar_events, [:calendar_integration_id, :uid])
    create_if_not_exists index(:provider_calendar_events, [:calendar_integration_id])
    create_if_not_exists index(:provider_calendar_events, [:calendar_integration_id, :start_at])
    create_if_not_exists index(:provider_calendar_events, [:calendar_integration_id, :start_date])
  end

  def down do
    # Irreversible in practice — downgrading would lose new columns.
    # Dev-only destructive path.
    drop_if_exists table(:provider_calendar_events)
  end
end
