defmodule Tymeslot.Repo.Migrations.AddSyncStateToProviderCalendarEvents do
  use Ecto.Migration

  def change do
    alter table(:provider_calendar_events) do
      # Offline write-queue bookkeeping. Non-"synced" rows have a local
      # change that has not yet been replayed to the server, and are
      # picked up by OfflineQueue.flush/2 at the start of every sync
      # cycle.
      #
      # Valid values:
      #   "synced"           — no pending work
      #   "locally_created"  — PUT not yet replayed
      #   "locally_modified" — update not yet replayed
      #   "locally_deleted"  — DELETE not yet replayed
      add(:sync_state, :string, null: false, default: "synced")
      add(:sync_attempts, :integer, null: false, default: 0)
      add(:sync_last_attempt_at, :utc_datetime_usec)
      add(:sync_last_error, :text)
    end

    # Partial index — only pending rows are indexed, so the main cache
    # lookups are unaffected and the pending-queue lookup is O(log P)
    # where P is the pending-queue size.
    create(
      index(:provider_calendar_events, [:calendar_integration_id, :sync_state],
        where: "sync_state <> 'synced'",
        name: :provider_calendar_events_pending_sync_idx
      )
    )
  end
end
