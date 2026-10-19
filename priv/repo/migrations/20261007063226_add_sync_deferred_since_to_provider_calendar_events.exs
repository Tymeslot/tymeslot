defmodule Tymeslot.Repo.Migrations.AddSyncDeferredSinceToProviderCalendarEvents do
  use Ecto.Migration

  # When a queued local change was first deferred by a replay that never got
  # an answer from the server, for as long as that has gone on without a
  # break. Nullable, no default: every existing row starts with no deferral.
  def change do
    alter table(:provider_calendar_events) do
      add :sync_deferred_since, :utc_datetime_usec
    end
  end
end
