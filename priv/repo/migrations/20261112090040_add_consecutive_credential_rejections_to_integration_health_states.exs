defmodule Tymeslot.Repo.Migrations.AddConsecutiveCredentialRejectionsToIntegrationHealthStates do
  use Ecto.Migration

  @moduledoc """
  Adds the streak of consecutive sync cycles a CalDAV-family server answered
  by rejecting the stored credentials.

  The sync worker flags such an integration for reconnection only once this
  streak reaches `ReauthHandling.password_rejection_threshold/0`. The general
  `consecutive_sync_failures` streak cannot stand in for it: it also counts
  timeouts and server errors, so a server coming back from an outage with one
  stray 401 would be believed at once. Any sync cycle that ends some other way
  breaks the streak, and so does reconnecting the integration.

  Existing rows start at 0: no rejection has been counted for them yet.
  """

  # PostgreSQL 11+ stores a non-volatile default in the catalogue rather than
  # rewriting the table, so this is a metadata-only change, as for
  # `consecutive_sync_failures`.
  def change do
    alter table(:integration_health_states) do
      # excellent_migrations:safety-assured-for-next-line column_added_with_default
      add :consecutive_credential_rejections, :integer, null: false, default: 0
    end
  end
end
