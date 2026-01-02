defmodule Tymeslot.Repo.Migrations.AddOnboardingCompletedAtToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :onboarding_completed_at, :utc_datetime
    end

    # Mark existing users as having completed onboarding
    execute("UPDATE users SET onboarding_completed_at = NOW() WHERE onboarding_completed_at IS NULL")
  end
end
