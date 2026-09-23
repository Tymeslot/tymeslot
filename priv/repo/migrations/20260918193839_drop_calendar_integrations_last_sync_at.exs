defmodule Tymeslot.Repo.Migrations.DropCalendarIntegrationsLastSyncAt do
  use Ecto.Migration

  # Two columns recorded "this integration synced", and only one of them was
  # ever read. `last_external_sync_at` drives the dashboard staleness banner
  # and the fallback sweep's cadence; `last_sync_at` was stamped by two of the
  # five sync workers, read by nothing, and existed mainly to mislead whoever
  # grepped for it next. Dropping it leaves one answer to the question.
  #
  # excellent_migrations:safety-assured-for-this-file column_removed
  #
  # The check guards against a rolling deploy where the previous release still
  # SELECTs the column. Tymeslot ships as a single container image per
  # deployment target and migrates on boot, so no build that knows the column
  # runs after this; the reverse direction restores it empty, which is exactly
  # what every row already held.
  def change do
    alter table(:calendar_integrations) do
      remove(:last_sync_at, :utc_datetime)
    end
  end
end
