defmodule Tymeslot.Repo.Migrations.AddAppleToCalendarProviderConstraint do
  use Ecto.Migration

  # Keep this list in sync with ProviderConfig.provider_constraint_list/0.
  # When adding a new provider, update both that function and the relevant migration.
  def up do
    execute(
      "ALTER TABLE calendar_integrations DROP CONSTRAINT IF EXISTS calendar_integrations_provider_check"
    )

    execute("""
    ALTER TABLE calendar_integrations
    ADD CONSTRAINT calendar_integrations_provider_check
    CHECK (provider IN ('caldav', 'radicale', 'nextcloud', 'zimbra', 'mailbox_org', 'apple', 'baikal', 'google', 'outlook', 'demo', 'debug'))
    """)
  end

  def down do
    # Re-home any iCloud integrations onto the generic CalDAV provider before
    # the constraint forbids 'apple', so existing rows stay valid.
    execute("UPDATE calendar_integrations SET provider = 'caldav' WHERE provider = 'apple'")

    execute(
      "ALTER TABLE calendar_integrations DROP CONSTRAINT IF EXISTS calendar_integrations_provider_check"
    )

    execute("""
    ALTER TABLE calendar_integrations
    ADD CONSTRAINT calendar_integrations_provider_check
    CHECK (provider IN ('caldav', 'radicale', 'nextcloud', 'zimbra', 'mailbox_org', 'baikal', 'google', 'outlook', 'demo', 'debug'))
    """)
  end
end
