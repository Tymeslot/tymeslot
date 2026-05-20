defmodule Tymeslot.Repo.Migrations.AddDashboardTourSeenAtToUsers do
  use Ecto.Migration

  def change do
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
end
