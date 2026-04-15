defmodule Tymeslot.Integrations.HealthCheck.SyncGating do
  @moduledoc """
  Determines which integrations should be paused from periodic sync work.

  An integration is **sync-paused** when its health state has accumulated
  enough consecutive hard failures (HTTP 401, `invalid_grant`, revoked
  tokens, etc.) that no retry can plausibly succeed without user action —
  typically reauthorisation. Pausing is purely a scheduler-side optimisation:
  the `is_active` flag is left untouched so the integration still appears in
  the user's dashboard and the health badge still surfaces the failure.

  When the user reauthorises, the next health check returns success,
  `failures` resets to 0, and the integration becomes syncable again on the
  following sweep.

  The threshold is configurable via
  `config :tymeslot, :sync_pause_hard_failure_threshold`. Default: 10.
  A 30-minute health check cadence turns 10 failures into roughly five hours
  of wasted retries before the scheduler backs off — short enough that users
  notice quickly, long enough that a transient outage misclassified as hard
  doesn't halt sync for hours.
  """

  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries

  @default_threshold 10

  @type integration_type :: :calendar | :video

  @doc """
  Returns the set of integration IDs of the given type whose health state is
  marked as having enough sustained hard failures that periodic sync should
  be skipped until the user reauthorises. The set is intended to be used as
  a filter against the output of `stream_all_active` / `list_all_active`
  in the fallback sweep.
  """
  @spec paused_integration_ids(integration_type()) :: MapSet.t(integer())
  def paused_integration_ids(type) do
    type
    |> IntegrationHealthStateQueries.list_ids_with_sustained_hard_failures(threshold())
    |> MapSet.new()
  end

  @doc """
  Predicate form: returns true when the integration (given its id and type)
  should be sync-paused according to its current health state.
  """
  @spec paused?(integration_type(), integer()) :: boolean()
  def paused?(type, integration_id) do
    type |> paused_integration_ids() |> MapSet.member?(integration_id)
  end

  @doc """
  The threshold (count of consecutive hard failures) above which an
  integration is considered sync-paused. Configurable for test scenarios.
  """
  @spec threshold() :: pos_integer()
  def threshold do
    Application.get_env(:tymeslot, :sync_pause_hard_failure_threshold, @default_threshold)
  end
end
