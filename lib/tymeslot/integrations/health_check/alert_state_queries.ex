defmodule Tymeslot.Integrations.HealthCheck.AlertStateQueries do
  @moduledoc """
  Reads and writes the persisted state of the hourly integration health
  signals (`Tymeslot.Integrations.HealthCheck.AlertStateSchema`).
  """

  import Ecto.Query

  alias Tymeslot.Integrations.HealthCheck.AlertStateSchema
  alias Tymeslot.Repo

  @doc """
  The state of `signal`, locked until the surrounding transaction ends, or
  nil when it has none yet.
  """
  @spec get_for_update(String.t()) :: AlertStateSchema.t() | nil
  def get_for_update(signal) do
    Repo.one(from(s in AlertStateSchema, where: s.signal == ^signal, lock: "FOR UPDATE"))
  end

  @doc "Inserts or replaces the state of `state.signal`."
  @spec put(AlertStateSchema.t()) :: AlertStateSchema.t()
  def put(%AlertStateSchema{} = state) do
    fields = [:status, :incident_started_at, :last_above_at, :last_window_end]

    Repo.insert!(struct(AlertStateSchema, Map.take(state, [:signal | fields])),
      on_conflict: {:replace, fields ++ [:updated_at]},
      conflict_target: :signal
    )
  end
end
