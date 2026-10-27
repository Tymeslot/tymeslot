defmodule Tymeslot.Repo.Migrations.IndexIntegrationHealthStatesByNextCheck do
  @moduledoc """
  Indexes integration health states by the time their next check is due, so
  the health sweep (`IntegrationHealthStateQueries.due/2`) reads only the
  rows that are due instead of every row on every run.

  The expression must stay identical to the one the query compares against,
  or the planner cannot use the index. `last_check_at` is a `timestamp`
  without time zone, so adding an interval to it is immutable and allowed
  in an index; a row never checked sorts first, as due since forever.

  Built concurrently, so it cannot run in a transaction. An interrupted
  build leaves an invalid index of this name behind, which the next run
  drops before building again.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @name :integration_health_states_next_check_index
  @columns [
    "integration_type",
    "(COALESCE(last_check_at, '-infinity'::timestamp) + backoff_ms * interval '1 millisecond')"
  ]

  def up do
    drop_if_exists(index(:integration_health_states, @columns, name: @name, concurrently: true))
    create(index(:integration_health_states, @columns, name: @name, concurrently: true))
  end

  def down do
    drop_if_exists(index(:integration_health_states, @columns, name: @name, concurrently: true))
  end
end
