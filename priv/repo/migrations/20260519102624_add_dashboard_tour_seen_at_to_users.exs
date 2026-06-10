defmodule Tymeslot.Repo.Migrations.AddDashboardTourSeenAtToUsers do
  use Ecto.Migration

  # Explicit up/0 + down/0 (rather than change/0) so rollback is reversible:
  # the backfill UPDATE has no automatic inverse, and a bare execute/1 inside
  # change/0 raises Ecto.MigrationError on `mix ecto.rollback`. On the way down
  # the backfill is a no-op (dropping the column discards the values anyway),
  # and the column drop reverses cleanly.
  def up do
    alter table(:users) do
      add(:dashboard_tour_seen_at, :utc_datetime)
    end

    # Existing fully-onboarded users have already seen the dashboard;
    # mark them seen so they don't get an overlay on a UI they know.
    # Users mid-onboarding (onboarding_completed_at IS NULL) are left
    # untouched so they see the tour after completing onboarding.
    execute(
      "UPDATE users SET dashboard_tour_seen_at = NOW() WHERE onboarding_completed_at IS NOT NULL"
    )
  end

  def down do
    alter table(:users) do
      remove(:dashboard_tour_seen_at)
    end
  end
end
