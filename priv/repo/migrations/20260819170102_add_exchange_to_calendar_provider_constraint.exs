defmodule Tymeslot.Repo.Migrations.AddExchangeToCalendarProviderConstraint do
  use Ecto.Migration

  # Swapping a CHECK constraint means dropping the old one and adding the new
  # one in the same breath, which Ecto's constraint helpers cannot express as
  # a single step; every prior provider-constraint migration does the same.
  # The rollback's DELETE is likewise raw by nature. Reviewed: the table is
  # small (one row per connected calendar per user) and the constraint is
  # validated against existing rows that already satisfy it, since the new
  # list is a superset of the old one.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed

  # Keep this list in sync with ProviderConfig.provider_constraint_list/0.
  # When adding a new provider, update both that function and the relevant
  # migration — except that this one deliberately lands ahead of it: 'exchange'
  # is admitted here before it exists in @providers, so the database is ready
  # while the changeset still refuses the value and nothing can create such a
  # row. The registry entry closes the gap in the commit that adds the provider.
  def up do
    execute(
      "ALTER TABLE calendar_integrations DROP CONSTRAINT IF EXISTS calendar_integrations_provider_check"
    )

    execute("""
    ALTER TABLE calendar_integrations
    ADD CONSTRAINT calendar_integrations_provider_check
    CHECK (provider IN ('caldav', 'radicale', 'nextcloud', 'zimbra', 'mailbox_org', 'apple', 'baikal', 'ics_url', 'google', 'outlook', 'exchange', 'demo', 'debug'))
    """)
  end

  # Like the ics_url rollback, this deletes rather than re-homing rows onto
  # 'caldav'. An Exchange integration speaks EWS over SOAP, not CalDAV, so a
  # re-homed row would fail every sync from the moment the rollback lands with
  # nothing in the UI to explain why. Its cached events cascade with it, and
  # nothing else can reference it: the provider is read-only, so an Exchange
  # calendar can never have been a meeting type's booking target.
  def down do
    execute("DELETE FROM calendar_integrations WHERE provider = 'exchange'")

    execute(
      "ALTER TABLE calendar_integrations DROP CONSTRAINT IF EXISTS calendar_integrations_provider_check"
    )

    execute("""
    ALTER TABLE calendar_integrations
    ADD CONSTRAINT calendar_integrations_provider_check
    CHECK (provider IN ('caldav', 'radicale', 'nextcloud', 'zimbra', 'mailbox_org', 'apple', 'baikal', 'ics_url', 'google', 'outlook', 'demo', 'debug'))
    """)
  end
end
