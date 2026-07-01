defmodule Tymeslot.Repo.Migrations.AddDashboardSetupWidgetState do
  use Ecto.Migration

  # Backs the dashboard onboarding widget: which setup items the host has
  # manually ticked off (`dashboard_setup_done_items`) and whether they closed
  # the whole widget (`dashboard_setup_dismissed_at`). Both default to the
  # "nothing hidden yet" state, so existing rows backfill safely.
  def change do
    alter table(:users) do
      add(:dashboard_setup_done_items, {:array, :string}, null: false, default: [])
      add(:dashboard_setup_dismissed_at, :utc_datetime)
    end
  end
end
