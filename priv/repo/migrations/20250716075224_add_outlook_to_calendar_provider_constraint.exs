defmodule Tymeslot.Repo.Migrations.AddOutlookToCalendarProviderConstraint do
  use Ecto.Migration

  def change do
    # Drop the existing constraint
    execute "ALTER TABLE calendar_integrations DROP CONSTRAINT IF EXISTS calendar_integrations_provider_check"

    # Add the new constraint including outlook
    execute "ALTER TABLE calendar_integrations ADD CONSTRAINT calendar_integrations_provider_check CHECK (provider IN ('radicale', 'google', 'outlook'))"
  end
end