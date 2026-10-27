defmodule Tymeslot.Repo.Migrations.IndexProviderCalendarEventsOnRecurringEventId do
  @moduledoc """
  Indexes cached events by their integration and the series master they
  name, which is how every series-wide query reaches a Google or Outlook
  series' occurrences: giving them their series' rule, finding the series
  whose rule is stale, forgetting the rules of series the cache no longer
  holds (`SeriesRuleQueries`), and deleting a series' rows.

  Built concurrently, so it cannot run in a transaction. An interrupted
  build leaves an invalid index of this name behind, which the next run
  drops before building again.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @name :provider_calendar_events_integration_recurring_event_id_index
  @columns [:calendar_integration_id, :recurring_event_id]

  def up do
    drop_if_exists(index(:provider_calendar_events, @columns, name: @name, concurrently: true))
    create(index(:provider_calendar_events, @columns, name: @name, concurrently: true))
  end

  def down do
    drop_if_exists(index(:provider_calendar_events, @columns, name: @name, concurrently: true))
  end
end
