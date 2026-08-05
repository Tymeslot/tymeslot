defmodule Tymeslot.Repo.Migrations.AddDeletedAtToVideoIntegrations do
  use Ecto.Migration

  # Deleting the provider-side rooms of a disconnected integration needs the
  # OAuth credentials the row holds, and that work runs in a background job, so
  # the row has to outlive the user's click. Marking it here and purging once the
  # cleanup drains is what keeps the credentials available exactly as long as
  # they are needed.
  #
  # No index: the only query filtering on this column is the per-user listing,
  # already bounded by user_id. Every unique index on the table is partial on
  # `is_active = true` and a soft-deleted row is also set inactive, so
  # reconnecting the same account immediately afterwards cannot collide.
  def change do
    alter table(:video_integrations) do
      add :deleted_at, :utc_datetime
    end
  end
end
