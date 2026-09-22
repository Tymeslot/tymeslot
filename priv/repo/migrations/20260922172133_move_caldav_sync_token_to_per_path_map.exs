defmodule Tymeslot.Repo.Migrations.MoveCaldavSyncTokenToPerPathMap do
  @moduledoc """
  Stores the CalDAV sync token per calendar path instead of once per
  integration.

  A `DAV:sync-token` and a `getctag` both describe a single collection, so a
  single string column could only ever hold the primary calendar's, and every
  other calendar on the integration was fetched in full on every cycle. The
  map is keyed by calendar path, in the same shape as `exchange_sync_states`
  beside it.

  The existing token is carried across as the primary path's entry, so the
  first sync after deploy continues from where it was rather than rebuilding
  every integration from scratch. Nullable with no database default, as
  `exchange_sync_states` is: a null already says "no calendar synced
  incrementally yet".
  """

  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # excellent_migrations:safety-assured-for-this-file column_removed
  #
  # The backfill is one UPDATE over `calendar_integrations`, a table of one row
  # per connected calendar account. The old column is dropped in the same
  # migration because Tymeslot ships as a single container image per
  # deployment target and migrates on boot, so no build that reads it runs
  # afterwards.

  use Ecto.Migration

  def up do
    alter table(:calendar_integrations) do
      add(:caldav_sync_tokens, :map)
    end

    execute("""
    UPDATE calendar_integrations
    SET caldav_sync_tokens = jsonb_build_object(calendar_paths[1], caldav_sync_token)
    WHERE caldav_sync_token IS NOT NULL
      AND calendar_paths[1] IS NOT NULL
    """)

    alter table(:calendar_integrations) do
      remove(:caldav_sync_token)
    end
  end

  def down do
    alter table(:calendar_integrations) do
      add(:caldav_sync_token, :string)
    end

    execute("""
    UPDATE calendar_integrations
    SET caldav_sync_token = caldav_sync_tokens ->> calendar_paths[1]
    WHERE caldav_sync_tokens IS NOT NULL
      AND calendar_paths[1] IS NOT NULL
    """)

    alter table(:calendar_integrations) do
      remove(:caldav_sync_tokens)
    end
  end
end
