defmodule Tymeslot.Integrations.HealthCheck.AlertStateSchema do
  @moduledoc """
  The persisted state of one hourly integration health signal (see
  `Tymeslot.Integrations.HealthCheck.Alerting`): whether it is in an
  incident, when that incident began, the last window it was at or above its
  threshold, and the last window evaluated.
  """
  use Ecto.Schema

  @type status :: :quiet | :raised

  @type t :: %__MODULE__{
          signal: String.t() | nil,
          status: status() | nil,
          incident_started_at: DateTime.t() | nil,
          last_above_at: DateTime.t() | nil,
          last_window_end: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:signal, :string, autogenerate: false}
  schema "integration_health_alert_states" do
    field(:status, Ecto.Enum, values: [:quiet, :raised])
    # Nil while raised means the incident began before the history the state
    # was first reconstructed from reaches back.
    field(:incident_started_at, :utc_datetime)
    field(:last_above_at, :utc_datetime)
    field(:last_window_end, :utc_datetime)

    timestamps(type: :utc_datetime)
  end
end
