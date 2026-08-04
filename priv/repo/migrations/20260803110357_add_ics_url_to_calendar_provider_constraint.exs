defmodule Tymeslot.Repo.Migrations.AddIcsUrlToCalendarProviderConstraint do
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
  # When adding a new provider, update both that function and the relevant migration.
  def up do
    execute(
      "ALTER TABLE calendar_integrations DROP CONSTRAINT IF EXISTS calendar_integrations_provider_check"
    )

    execute("""
    ALTER TABLE calendar_integrations
    ADD CONSTRAINT calendar_integrations_provider_check
    CHECK (provider IN ('caldav', 'radicale', 'nextcloud', 'zimbra', 'mailbox_org', 'apple', 'baikal', 'ics_url', 'google', 'outlook', 'demo', 'debug'))
    """)
  end

  # Unlike the other provider constraint migrations, this one deletes rather
  # than re-homing rows onto 'caldav'. A subscription carries no CalDAV
  # credentials and speaks no CalDAV protocol, so a re-homed row would be an
  # integration that fails every sync from the moment the rollback lands, with
  # nothing in the UI to explain why. Its cached events cascade with it, and
  # nothing else can reference it: a subscription's only calendar is read-only,
  # so it can never have been a meeting type's booking target.
  def down do
    execute("DELETE FROM calendar_integrations WHERE provider = 'ics_url'")

    execute(
      "ALTER TABLE calendar_integrations DROP CONSTRAINT IF EXISTS calendar_integrations_provider_check"
    )

    execute("""
    ALTER TABLE calendar_integrations
    ADD CONSTRAINT calendar_integrations_provider_check
    CHECK (provider IN ('caldav', 'radicale', 'nextcloud', 'zimbra', 'mailbox_org', 'apple', 'baikal', 'google', 'outlook', 'demo', 'debug'))
    """)
  end
end
