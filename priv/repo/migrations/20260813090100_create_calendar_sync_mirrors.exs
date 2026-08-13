defmodule Tymeslot.Repo.Migrations.CreateCalendarSyncMirrors do
  use Ecto.Migration

  # Both assurances apply because the table is created empty in this same
  # migration: there are no rows for the indexes to lock out, and both
  # references are declared as part of CREATE TABLE rather than added to a
  # table already holding data, so nothing a running deploy reads is locked.
  # Building the indexes concurrently is not possible here in any case, since
  # CREATE INDEX CONCURRENTLY cannot run inside the transaction a migration
  # runs in.
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file column_reference_added

  # One row per mirrored event: the mapping from a source event's UID to the
  # placeholder written on the target, plus the provider bookkeeping needed to
  # decide whether a re-write is required.
  #
  # Deliberately its own table rather than a tag on `provider_calendar_events`.
  # `provider_metadata` is the only map column there and it is listed in
  # `replace_fields/0` (provider_calendar_event_queries.ex), so every inbound
  # sync overwrites it wholesale with the raw provider payload. A mapping
  # stored there would survive until the next sync and then vanish, taking with
  # it the only record of which provider event to update or delete — leaving an
  # orphaned placeholder on the target that nothing owns. The cache is a
  # projection of provider state; this is Tymeslot's own bookkeeping.
  def change do
    create table(:calendar_sync_mirrors) do
      add(:sync_link_id, references(:calendar_sync_links, on_delete: :delete_all), null: false)

      add(:source_uid, :string, null: false)

      # Denormalised from the link. The engine reads this table forwards, from
      # a link and a source UID; the calendar grid reads it backwards, holding
      # UIDs cached against a target integration and asking which of them are
      # mirrors it should hide. Without this column the target integration is
      # reachable only by joining through the link, so the backwards question
      # cannot be indexed at all and degrades to a sequential scan on every
      # grid render — and the grid re-renders on navigation, on live cache
      # updates, and on every appearance change.
      add(:target_integration_id, references(:calendar_integrations, on_delete: :delete_all),
        null: false
      )

      add(:target_provider_event_id, :string)
      add(:target_uid, :string, null: false)

      # The source's provider_updated_at and etag as of the last successful
      # write. Together they answer "has the source moved since we mirrored
      # it?" without refetching the mirror from the target.
      add(:source_updated_at, :utc_datetime_usec)
      add(:source_etag, :string)

      # The mirror's own etag, used as a CalDAV If-Match precondition so a
      # host-side edit since the last write makes the PUT return 412 rather
      # than silently reverting the edit.
      add(:target_etag, :string)

      add(:last_synced_at, :utc_datetime_usec)
      add(:state, :string, null: false, default: "active")

      timestamps(type: :utc_datetime_usec)
    end

    # Every index below is named explicitly: the derived names exceed
    # Postgres' 63-character identifier limit and would be silently truncated,
    # leaving each index under a name no later migration could predict in order
    # to drop it.

    # The engine's mapping lookup, and the guarantee that one source event
    # produces at most one mirror per link.
    create(
      unique_index(:calendar_sync_mirrors, [:sync_link_id, :source_uid],
        name: :calendar_sync_mirrors_link_source_uid_index
      )
    )

    # The reconciliation sweep's scan: pending_delete and failed rows for one
    # link.
    create(
      index(:calendar_sync_mirrors, [:sync_link_id, :state],
        name: :calendar_sync_mirrors_link_state_index
      )
    )

    # The grid's hide lookup, read backwards from the target. See the comment
    # on target_integration_id above for why this cannot be served by the
    # link-keyed indexes.
    create(
      index(:calendar_sync_mirrors, [:target_integration_id, :target_uid],
        name: :calendar_sync_mirrors_target_uid_index
      )
    )
  end
end
