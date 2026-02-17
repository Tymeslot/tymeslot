defmodule Tymeslot.Workers.IntegrationHealthWorker do
  @moduledoc """
  Oban worker for performing health checks on individual integrations.
  """

  @unique_period_seconds 300

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
        case HealthCheck.perform_single_check(type, integration_id) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Integration health check returned error",
              type: type,
              integration_id: integration_id,
              reason: reason,
              job_id: job.id
            )

            :ok
        end
    end
  end

  def perform(_job) do
    {:discard, "Invalid arguments"}
  end

  defp parse_type("calendar"), do: :calendar
  defp parse_type("video"), do: :video
  defp parse_type(_type), do: nil
end
