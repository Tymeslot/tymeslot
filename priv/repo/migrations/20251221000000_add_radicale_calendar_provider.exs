defmodule Tymeslot.Repo.Migrations.AddRadicaleCalendarProvider do
  use Ecto.Migration

  def up do
    # Drop the existing constraint
    execute "ALTER TABLE calendar_integrations DROP CONSTRAINT IF EXISTS calendar_integrations_provider_check"
    
    # Create new constraint with 'radicale' added alongside 'caldav'
    # Both providers coexist - users can choose which one to use
    # Include 'debug' for development/testing purposes
    execute """
    ALTER TABLE calendar_integrations 
    ADD CONSTRAINT calendar_integrations_provider_check 
    CHECK (provider IN ('caldav', 'radicale', 'nextcloud', 'google', 'outlook', 'debug'))
    """
  end

  def down do
    # Update any 'radicale' entries back to 'caldav' for safe rollback
    execute "UPDATE calendar_integrations SET provider = 'caldav' WHERE provider = 'radicale'"
    
    # Drop the constraint
    execute "ALTER TABLE calendar_integrations DROP CONSTRAINT IF EXISTS calendar_integrations_provider_check"
    
    # Recreate constraint without 'radicale' (but keep debug for testing)
    execute """
    ALTER TABLE calendar_integrations 
    ADD CONSTRAINT calendar_integrations_provider_check 
    CHECK (provider IN ('caldav', 'nextcloud', 'google', 'outlook', 'debug'))
    """
  end
end