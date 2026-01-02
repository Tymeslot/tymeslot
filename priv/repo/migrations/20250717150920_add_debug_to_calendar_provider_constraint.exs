defmodule Tymeslot.Repo.Migrations.AddDebugToCalendarProviderConstraint do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE calendar_integrations DROP CONSTRAINT IF EXISTS calendar_integrations_provider_check"
    execute "ALTER TABLE calendar_integrations ADD CONSTRAINT calendar_integrations_provider_check CHECK (provider IN ('caldav', 'google', 'outlook', 'apple', 'debug'))"
  end

  def down do
    execute "ALTER TABLE calendar_integrations DROP CONSTRAINT IF EXISTS calendar_integrations_provider_check"
    execute "ALTER TABLE calendar_integrations ADD CONSTRAINT calendar_integrations_provider_check CHECK (provider IN ('caldav', 'google', 'outlook', 'apple'))"
  end
end