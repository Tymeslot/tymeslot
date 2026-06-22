defmodule Tymeslot.Repo.Migrations.AddDeviceTypeToAnalyticsEvents do
  use Ecto.Migration

  # Nullable, no backfill: device_type is derived from the user-agent at
  # ingest time and we never persist the raw UA, so existing rows simply
  # carry NULL (surfaced as "unknown" in the dashboard).
  def change do
    alter table(:analytics_events) do
      add(:device_type, :string)
    end
  end
end
