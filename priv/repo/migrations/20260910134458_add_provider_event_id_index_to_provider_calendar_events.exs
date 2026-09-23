defmodule Tymeslot.Repo.Migrations.AddProviderEventIdIndexToProviderCalendarEvents do
  use Ecto.Migration

  @moduledoc """
  Restores an index on `(calendar_integration_id, provider_event_id)`.

  The column has been unindexed since `20260408110831` dropped the legacy
  `calendar_events_calendar_integration_id_provider_event_id_index` and did not
  recreate it under the renamed table. That was fine while nothing looked a row
  up by it, but the outbound write-through in
  `Tymeslot.Meetings.CalendarEventSync` now resolves a meeting to its cached
  event through `ProviderCalendarEventQueries.get_by_identifiers/2`, which
  matches `uid` *or* `provider_event_id` — and with only the first column
  indexed, PostgreSQL cannot build the bitmap OR and falls back to scanning the
  whole event cache on every calendar update.

  Not unique, deliberately: an expanded occurrence of a recurring series
  carries its parent's `provider_event_id`, so duplicates are legitimate here
  and `get_by_identifiers/2` takes the first row rather than assuming
  otherwise. Uniqueness lives on `(calendar_integration_id, uid)`, where it
  belongs.
  """

  # Concurrently, so an existing installation's event cache — which can hold
  # every event of every connected calendar — is not write-locked for the
  # duration. That is what forces both flags off.
  @disable_ddl_transaction true
  @disable_migration_lock true

  # Named explicitly: the generated name is two characters past PostgreSQL's
  # 63-byte identifier limit and would be silently truncated.
  @index_name :provider_calendar_events_integration_provider_event_id_index

  def up do
    create_if_not_exists(
      index(
        :provider_calendar_events,
        [:calendar_integration_id, :provider_event_id],
        name: @index_name,
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(
        :provider_calendar_events,
        [:calendar_integration_id, :provider_event_id],
        name: @index_name,
        concurrently: true
      )
    )
  end
end
