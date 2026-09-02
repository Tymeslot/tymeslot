defmodule Tymeslot.Repo.Migrations.AddConsecutiveSyncFailuresToIntegrationHealthStates do
  use Ecto.Migration

  @moduledoc """
  Adds the counter that lets a failing *sync* mark an integration unhealthy.

  Until now the only thing that could move an integration's health status was
  the scheduled probe, and the probe is not the request that syncs run: it
  PROPFINDs a collection where sync issues a REPORT. A server can answer one
  and refuse the other, so an integration could fail almost every sync for
  weeks while every probe passed and the badge stayed green.

  `consecutive_sync_failures` records the streak of failed sync cycles. It is
  reset by `IntegrationHealthStateQueries.reset/2` (which a successful sync
  already calls through `HealthCheck.mark_synced_successfully/2`) and is
  deliberately not written by the probe, so the two signals cannot clobber
  each other.

  Existing rows start at 0: no streak has been observed for them, and a
  genuinely broken integration re-establishes its streak within a couple of
  sync cycles.
  """

  # PostgreSQL 11+ stores a non-volatile default in the catalogue rather than
  # rewriting the table, so this is a metadata-only change. Migrations also run
  # offline here (`start.sh` runs them in a one-shot VM and only starts Phoenix
  # once they finish), so no live traffic waits on the lock either way.
  def change do
    alter table(:integration_health_states) do
      # excellent_migrations:safety-assured-for-next-line column_added_with_default
      add :consecutive_sync_failures, :integer, null: false, default: 0
    end
  end
end
