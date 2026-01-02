defmodule Tymeslot.Repo.Migrations.RemoveAppleFromCalendarProviderConstraint do
  use Ecto.Migration

  def up do
    # Drop the existing constraint
    execute """
    ALTER TABLE calendar_integrations 
    DROP CONSTRAINT calendar_integrations_provider_check
    """

    # Add the new constraint without 'apple'
    execute """
    ALTER TABLE calendar_integrations 
    ADD CONSTRAINT calendar_integrations_provider_check 
    CHECK (provider IN ('caldav', 'google', 'outlook', 'debug', 'nextcloud'))
    """
  end

  def down do
    # Drop the new constraint
    execute """
    ALTER TABLE calendar_integrations 
    DROP CONSTRAINT calendar_integrations_provider_check
    """

    # Restore the constraint with 'apple' included
    execute """
    ALTER TABLE calendar_integrations 
    ADD CONSTRAINT calendar_integrations_provider_check 
    CHECK (provider IN ('caldav', 'google', 'outlook', 'apple', 'debug', 'nextcloud'))
    """
  end
end