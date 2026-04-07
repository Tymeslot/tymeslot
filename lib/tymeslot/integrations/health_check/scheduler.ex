defmodule Tymeslot.Integrations.HealthCheck.Scheduler do
  @moduledoc """
  Domain: Intelligent Check Timing

  Determines when health checks should run based on backoff strategies,
  circuit breaker state, and jitter. Prevents system overload through
  intelligent scheduling and duplicate prevention.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries

  alias Tymeslot.Infrastructure.{CalendarCircuitBreaker, VideoCircuitBreaker}
  alias Tymeslot.Integrations.HealthCheck.{Monitor, ProviderHelpers}
  alias Tymeslot.Workers.IntegrationHealthWorker

  @max_jitter_ms 30_000

  @type integration_type :: :calendar | :video

  @doc """
  Schedules health check jobs for all active integrations.
  Health state is read from the database per-integration to determine if a check is due.
  """
  @spec schedule_all(keyword()) :: :ok
  def schedule_all(opts \\ []) do
    now = DateTime.utc_now()
    force = Keyword.get(opts, :force, false)

    Enum.each(CalendarIntegrationQueries.list_all_active(), fn int ->
      schedule_if_due(:calendar, int, now, force)
    end)

    Enum.each(VideoIntegrationQueries.list_all_active(), fn int ->
      schedule_if_due(:video, int, now, force)
    end)

    IntegrationHealthStateQueries.delete_orphaned()

    :ok
  end

  @doc """
  Determines if a check is due based on health state and current time.
  """
  @spec due_for_check?(Monitor.health_state(), DateTime.t()) :: boolean()
  def due_for_check?(%{last_check_at: nil}, _now), do: true

  def due_for_check?(%{last_check_at: last_check_at, backoff_ms: backoff_ms}, now) do
    next_time = DateTime.add(last_check_at, backoff_ms, :millisecond)
    DateTime.compare(next_time, now) != :gt
  end

  @doc """
  Creates a scheduled timestamp with random jitter to prevent thundering herd.
  """
  @spec scheduled_at_with_jitter() :: DateTime.t()
  def scheduled_at_with_jitter do
    jitter_ms = :rand.uniform(@max_jitter_ms + 1) - 1
    DateTime.add(DateTime.utc_now(), jitter_ms, :millisecond)
  end

  # Private Functions

  defp schedule_if_due(type, integration, now, force) do
    health_state = Monitor.get_state(type, integration.id, integration.user_id)

    if force || due_for_check?(health_state, now) do
      Logger.debug("Scheduling integration health check",
        type: type,
        integration_id: integration.id,
        provider: integration.provider,
        backoff_ms: health_state.backoff_ms,
        last_error_class: health_state.last_error_class
      )

      enqueue_if_allowed(type, integration)
    else
      Logger.debug("Skipping integration health check (backoff)",
        type: type,
        integration_id: integration.id,
        provider: integration.provider,
        backoff_ms: health_state.backoff_ms,
        last_error_class: health_state.last_error_class
      )
    end
  end

  defp enqueue_if_allowed(type, integration) do
    if should_skip_due_to_circuit?(type, integration) do
      :ok
    else
      enqueue_job(type, integration.id)
    end
  end

  defp enqueue_job(type, integration_id) do
    job =
      IntegrationHealthWorker.new(
        %{
          "type" => Atom.to_string(type),
          "integration_id" => integration_id
        },
        scheduled_at: scheduled_at_with_jitter()
      )

    result = Oban.insert(job)

    case result do
      {:ok, _job} ->
        :ok

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        case Keyword.get(errors, :unique) do
          nil ->
            Logger.error("Failed to enqueue integration health check",
              type: type,
              integration_id: integration_id,
              errors: errors
            )

            {:error, changeset}

          _unique_error ->
            Logger.debug("Health check job already pending (unique constraint)",
              type: type,
              integration_id: integration_id
            )

            :ok
        end
    end
  end

  defp should_skip_due_to_circuit?(type, integration) do
    provider_atom = ProviderHelpers.safe_to_existing_atom(integration.provider)

    if provider_atom do
      check_circuit_breaker(type, integration, provider_atom)
    else
      false
    end
  end

  defp check_circuit_breaker(type, integration, provider_atom) do
    circuit_status =
      try do
        case type do
          :calendar -> CalendarCircuitBreaker.status(provider_atom)
          :video -> VideoCircuitBreaker.status(provider_atom)
        end
      rescue
        e ->
          Logger.error("Circuit breaker status check failed",
            type: type,
            provider: integration.provider,
            error: inspect(e)
          )

          {:error, :status_check_failed}
      end

    case circuit_status do
      %{status: :open} ->
        Logger.info("Circuit breaker open, skipping health check enqueue",
          type: type,
          provider: integration.provider,
          integration_id: integration.id
        )

        true

      %{status: :half_open} ->
        false

      %{status: :closed} ->
        false

      {:error, :breaker_not_found} ->
        Logger.error("Circuit breaker not initialized, proceeding with health check",
          type: type,
          provider: integration.provider,
          integration_id: integration.id
        )

        false

      {:error, :status_check_failed} ->
        Logger.error("Circuit breaker status check failed, proceeding with health check",
          type: type,
          provider: integration.provider,
          integration_id: integration.id
        )

        false

      {:error, {:invalid_provider, _provider}} ->
        # Provider has no circuit breaker (e.g. custom URL integrations) — always proceed
        false

      unknown ->
        Logger.warning("Unknown circuit breaker status, proceeding with health check",
          type: type,
          provider: integration.provider,
          integration_id: integration.id,
          status: inspect(unknown)
        )

        false
    end
  end
end
