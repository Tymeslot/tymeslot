defmodule Tymeslot.Workers.IntegrationHealthWorker do
  @moduledoc """
  Oban worker for performing health checks on individual integrations.
  """

  @unique_period_seconds 300
  @job_timeout_ms 120_000

  use Oban.Worker,
    queue: :calendar_integrations,
    max_attempts: 3,
    priority: 2,
    unique: [
      fields: [:worker, :args],
      period: @unique_period_seconds,
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  require Logger
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Integrations.Shared.IntegrationTypes
  alias Tymeslot.Workers.Bounded

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"type" => type_str, "integration_id" => integration_id}} = job)
      when is_binary(type_str) and is_integer(integration_id) do
    Logger.debug("IntegrationHealthWorker performing job",
      args: LogFormat.reason(job.args),
      job_id: job.id
    )

    case IntegrationTypes.parse(type_str) do
      {:ok, type} -> run_with_timeout(type, integration_id, job.id)
      :error -> {:discard, "Invalid integration type"}
    end
  end

  def perform(_job) do
    {:discard, "Invalid arguments"}
  end

  defp run_with_timeout(type, integration_id, job_id) do
    timeout_ms = Application.get_env(:tymeslot, :health_check_timeout_ms, @job_timeout_ms)

    case Bounded.run(
           fn -> health_check_module().perform_single_check(type, integration_id) end,
           timeout_ms
         ) do
      {:ok, :ok} ->
        :ok

      # Already logged, classified, as a warning by `HealthCheck.ErrorAnalysis`.
      {:ok, {:error, reason}} ->
        Logger.debug("Integration health check returned error",
          type: type,
          integration_id: integration_id,
          reason: LogFormat.reason(reason),
          job_id: job_id
        )

        :ok

      {:exit, reason} ->
        Logger.error("Integration health check crashed",
          type: type,
          integration_id: integration_id,
          reason: LogFormat.reason(reason),
          job_id: job_id
        )

        :ok

      :timeout ->
        Logger.warning("Integration health check timed out",
          type: type,
          integration_id: integration_id,
          timeout_ms: timeout_ms,
          job_id: job_id
        )

        :ok
    end
  end

  defp health_check_module do
    Application.get_env(:tymeslot, :health_check_module, HealthCheck)
  end
end
