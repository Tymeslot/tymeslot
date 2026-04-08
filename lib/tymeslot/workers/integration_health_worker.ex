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
      states: [:available, :scheduled, :executing, :retryable]
    ]

  require Logger
  alias Tymeslot.Integrations.HealthCheck

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"type" => type_str, "integration_id" => integration_id}} = job)
      when is_binary(type_str) and is_integer(integration_id) do
    Logger.debug("IntegrationHealthWorker performing job",
      args: inspect(job.args),
      job_id: job.id
    )

    case parse_type(type_str) do
      nil ->
        {:discard, "Invalid integration type"}

      type ->
        run_with_timeout(type, integration_id, job.id)
    end
  end

  def perform(_job) do
    {:discard, "Invalid arguments"}
  end

  defp run_with_timeout(type, integration_id, job_id) do
    task =
      Task.Supervisor.async(Tymeslot.TaskSupervisor, fn ->
        health_check_module().perform_single_check(type, integration_id)
      end)

    timeout_ms = Application.get_env(:tymeslot, :health_check_timeout_ms, @job_timeout_ms)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, reason}} ->
        Logger.warning("Integration health check returned error",
          type: type,
          integration_id: integration_id,
          reason: reason,
          job_id: job_id
        )

        :ok

      nil ->
        Logger.warning("Integration health check timed out",
          type: type,
          integration_id: integration_id,
          timeout_ms: timeout_ms,
          job_id: job_id
        )

        :ok
    end
  end

  defp parse_type("calendar"), do: :calendar
  defp parse_type("video"), do: :video
  defp parse_type(_type), do: nil

  defp health_check_module do
    Application.get_env(:tymeslot, :health_check_module, HealthCheck)
  end
end
