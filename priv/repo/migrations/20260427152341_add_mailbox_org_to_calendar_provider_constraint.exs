defmodule Tymeslot.Repo.Migrations.AddMailboxOrgToCalendarProviderConstraint do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE calendar_integrations DROP CONSTRAINT IF EXISTS calendar_integrations_provider_check"

    execute """
    ALTER TABLE calendar_integrations
    ADD CONSTRAINT calendar_integrations_provider_check
    CHECK (provider IN ('caldav', 'radicale', 'nextcloud', 'zimbra', 'mailbox_org', 'google', 'outlook', 'debug'))
    """
  end

  def down do
    execute "UPDATE calendar_integrations SET provider = 'caldav' WHERE provider = 'mailbox_org'"

    execute "ALTER TABLE calendar_integrations DROP CONSTRAINT IF EXISTS calendar_integrations_provider_check"

    execute """
    ALTER TABLE calendar_integrations
    ADD CONSTRAINT calendar_integrations_provider_check
    CHECK (provider IN ('caldav', 'radicale', 'nextcloud', 'zimbra', 'google', 'outlook', 'debug'))
    """
  end
end
