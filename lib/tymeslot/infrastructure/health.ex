defmodule Tymeslot.Infrastructure.Health do
  @moduledoc """
  Answers whether this instance can do its job: reach its database and run
  its background jobs.

  The report backs the public `/healthcheck` endpoint, which container
  orchestrators (Cloudron's `healthCheckPath` among them) poll to decide
  whether to restart the app. The overall status is the worst of the checks:

  | Status | Meaning | Checks |
  |--------|---------|--------|
  | `:ok` | Fully working | every check `:ok` |
  | `:degraded` | Serving, but some work is on hold; a restart would not help | an Oban queue `:paused`, nothing `:unavailable` |
  | `:unhealthy` | Cannot do its job | any check `:unavailable` |

  A paused queue is an operator's deliberate act and survives a restart, so it
  must not make the orchestrator restart the instance in a loop.
  """

  require Logger

  alias Tymeslot.Infrastructure.HealthQueries

  @type check_status :: :ok | :paused | :unavailable
  @type checks :: %{database: check_status(), oban: check_status()}
  @type status :: :ok | :degraded | :unhealthy
  @type report :: %{status: status(), checks: checks()}

  @doc """
  Runs every check and summarises them.
  """
  @spec check() :: report()
  def check do
    checks = %{database: check_database(), oban: check_oban()}
    %{status: summarise(checks), checks: checks}
  end

  defp summarise(checks) do
    statuses = Map.values(checks)

    cond do
      :unavailable in statuses -> :unhealthy
      :paused in statuses -> :degraded
      true -> :ok
    end
  end

  defp check_database do
    case HealthQueries.ping() do
      :ok -> :ok
      {:error, _reason} -> :unavailable
    end
  rescue
    exception ->
      Logger.error("Healthcheck database probe raised", error: Exception.message(exception))
      :unavailable
  end

  defp check_oban do
    if Enum.any?(Oban.check_all_queues(), & &1.paused), do: :paused, else: :ok
  rescue
    exception ->
      Logger.error("Healthcheck Oban probe raised", error: Exception.message(exception))
      :unavailable
  end
end
