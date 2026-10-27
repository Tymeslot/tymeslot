defmodule Tymeslot.Repo.Migrations.CreateIntegrationHealthAlertStates do
  @moduledoc """
  One row per hourly integration health signal, holding whether it is in an
  incident, when the incident began and when the signal was last at or above
  its threshold, so the hourly alert run reads its own state instead of
  re-deriving it by walking back over up to a day of windows.

  A new, empty table. Existing installations start with no rows; the first
  run for each signal reconstructs its state from history once (see
  `Tymeslot.Integrations.HealthCheck.Alerting`).
  """

  use Ecto.Migration

  def change do
    create table(:integration_health_alert_states, primary_key: false) do
      add :signal, :string, primary_key: true
      add :status, :string, null: false
      add :incident_started_at, :utc_datetime
      add :last_above_at, :utc_datetime
      add :last_window_end, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
