defmodule Tymeslot.Repo.Migrations.AddMeetingPaymentsEnabledToAppSettings do
  use Ecto.Migration

  def change do
    alter table(:app_settings) do
      add :meeting_payments_enabled, :boolean
    end
  end
end
