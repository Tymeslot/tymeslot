defmodule Tymeslot.Infrastructure.Health do
  @moduledoc """
  Answers whether this instance can do its job: reach its database and run
  its background jobs.

  The report backs the public `/healthcheck` endpoint, which container
  orchestrators (Cloudron's `healthCheckPath` among them) poll to decide
  whether to restart the app, so every check here is essential: any check
  that is not `:ok` makes the whole instance `:unhealthy`.
  """

  require Logger

  alias Tymeslot.Infrastructure.HealthQueries

  @type check_status :: :ok | :paused | :unavailable
  @type checks :: %{database: check_status(), oban: check_status()}
  @type report :: %{status: :ok | :unhealthy, checks: checks()}

  @doc """
  Runs every check and summarises them.
  """
  @spec check() :: report()
  def check do
    checks = %{database: check_database(), oban: check_oban()}
    %{status: summarise(checks), checks: checks}
  end

  defp summarise(checks) do
    if Enum.all?(checks, fn {_name, status} -> status == :ok end), do: :ok, else: :unhealthy
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
