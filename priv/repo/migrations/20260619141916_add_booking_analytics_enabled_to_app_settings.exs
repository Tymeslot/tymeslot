defmodule Tymeslot.Repo.Migrations.AddBookingAnalyticsEnabledToAppSettings do
  use Ecto.Migration

  # Nullable boolean: NULL means "no DB override" — the effective value then
  # falls back to the config layer (Core default false, SaaS override true) and
  # finally the built-in default. Admin toggling writes a concrete true/false.
  def change do
    alter table(:app_settings) do
      add_if_not_exists(:booking_analytics_enabled, :boolean)
    end
  end
end
