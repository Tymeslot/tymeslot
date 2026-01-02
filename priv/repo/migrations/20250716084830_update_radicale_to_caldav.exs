defmodule Tymeslot.Repo.Migrations.UpdateRadicaleToCaldav do
  use Ecto.Migration

  def up do
    # First, update existing 'radicale' providers to 'caldav'
    execute "UPDATE calendar_integrations SET provider = 'caldav' WHERE provider = 'radicale'"
    
    # Drop the existing constraint
    execute "ALTER TABLE calendar_integrations DROP CONSTRAINT IF EXISTS calendar_integrations_provider_check"
    
    # Create new constraint with 'caldav' instead of 'radicale'
    execute "ALTER TABLE calendar_integrations ADD CONSTRAINT calendar_integrations_provider_check CHECK (provider IN ('caldav', 'google', 'outlook'))"
  end

  def down do
    # Update 'caldav' back to 'radicale' for rollback
    execute "UPDATE calendar_integrations SET provider = 'radicale' WHERE provider = 'caldav'"
    
    # Drop the constraint
    execute "ALTER TABLE calendar_integrations DROP CONSTRAINT IF EXISTS calendar_integrations_provider_check"
    
    # Recreate original constraint
    execute "ALTER TABLE calendar_integrations ADD CONSTRAINT calendar_integrations_provider_check CHECK (provider IN ('radicale', 'google', 'outlook'))"
  end
end