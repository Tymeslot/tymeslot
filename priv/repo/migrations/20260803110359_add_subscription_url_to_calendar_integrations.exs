defmodule Tymeslot.Repo.Migrations.AddSubscriptionUrlToCalendarIntegrations do
  use Ecto.Migration

  # Holds the encrypted feed URL of an `ics_url` subscription. It lives in its
  # own column rather than in `base_url` because for that provider the URL is
  # the credential: a published feed link grants read access to the whole
  # calendar to anyone who holds it. Nullable with no default and no backfill —
  # every existing row is a provider that has no feed URL to store.
  def change do
    alter table(:calendar_integrations) do
      add :subscription_url_encrypted, :binary
    end
  end
end
