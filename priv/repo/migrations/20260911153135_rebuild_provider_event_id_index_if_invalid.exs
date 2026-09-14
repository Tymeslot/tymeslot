defmodule Tymeslot.Repo.Migrations.RebuildProviderEventIdIndexIfInvalid do
  @moduledoc """
  Rebuilds `provider_calendar_events (calendar_integration_id,
  provider_event_id)` so an installation that was interrupted while
  `20260910134458` built it ends up with a usable index rather than a
  permanently invalid one.

  `CREATE INDEX CONCURRENTLY` cannot run inside a transaction, so an
  interruption — a container restart mid-migration, a health-check kill, a
  dropped connection — leaves the half-built index behind marked
  `pg_index.indisvalid = false` instead of rolling it back. The migration
  itself fails, so its version is never recorded; on the next boot the migrator
  runs it again, `create_if_not_exists` finds an index of that name, skips the
  create, and *this* time records the version. The invalid index then survives
  forever: the planner ignores it, so
  `ProviderCalendarEventQueries.get_by_identifiers/2` quietly goes back to
  scanning the whole event cache, on that installation only, with nothing in
  the logs.

  Dropping first is what breaks that cycle, and it is the convention
  `20260902120100_add_unique_index_to_held_meetings` already established for a
  concurrently-built index. The drop is unconditional rather than guarded on
  `indisvalid`: dropping a healthy index costs exactly the concurrent rebuild
  that follows it, and a guard would need raw SQL to read the catalogue.

  The index this rebuilds is unchanged in shape — see `20260910134458` for why
  it is deliberately not unique (an expanded occurrence of a recurring series
  carries its parent's `provider_event_id`) and why the name is set explicitly
  (the generated name is 72 bytes, nine past PostgreSQL's 63-byte identifier
  limit, and would be silently truncated).

  Installations whose original build completed normally get a rebuild of an
  index they already had, which is the cost of not being able to tell the two
  cases apart from a migration. Every other concurrently-built index in this
  schema is left alone and covered instead by the boot-time check in
  `Tymeslot.Infrastructure.IndexHealth`, which names any index PostgreSQL is
  ignoring so an operator can `REINDEX INDEX CONCURRENTLY` just that one.
  """

  use Ecto.Migration

  # Concurrently on both statements, so an existing installation's event cache
  # is never write-locked. That is what forces both flags off.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @index_name :provider_calendar_events_integration_provider_event_id_index

  @columns [:calendar_integration_id, :provider_event_id]

  def up do
    drop_if_exists(
      index(:provider_calendar_events, @columns, name: @index_name, concurrently: true)
    )

    create(index(:provider_calendar_events, @columns, name: @index_name, concurrently: true))
  end

  def down do
    # Deliberately a no-op. This migration does not own the index — it only
    # rebuilds what `20260910134458` created, so rolling it back must leave the
    # index in place for that migration's own `down/0` to drop.
    :ok
  end
end
