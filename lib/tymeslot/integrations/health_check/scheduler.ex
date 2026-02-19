defmodule Tymeslot.Integrations.HealthCheck.Scheduler do
  @moduledoc """
  Domain: Intelligent Check Timing

  Determines when health checks should run based on backoff strategies,
  circuit breaker state, and jitter. Prevents system overload through
  intelligent scheduling and duplicate prevention.
  """

  require Logger

  alias Tymeslot.DatabaseQueries.{CalendarIntegrationQueries, VideoIntegrationQueries}
  alias Tymeslot.Infrastructure.{CalendarCircuitBreaker, VideoCircuitBreaker}
  alias Tymeslot.Integrations.HealthCheck.Monitor
  alias Tymeslot.Workers.IntegrationHealthWorker

  @max_jitter_ms 30_000
  @max_backoff :timer.hours(1)
  @check_interval :timer.minutes(30)

  @type integration_type :: :calendar | :video

  @doc """
  Schedules health check jobs for all active integrations.
  Returns updated state with scheduled jobs.
  """
  @spec schedule_all(map(), keyword()) :: {map(), :ok}
  def schedule_all(state, opts \\ []) do
    now = DateTime.utc_now()
    force = Keyword.get(opts, :force, false)

    state =
      Enum.reduce(CalendarIntegrationQueries.list_all_active(), state, fn int, acc ->
        schedule_if_due(:calendar, int, acc, now, force)
      end)

    state =
      Enum.reduce(VideoIntegrationQueries.list_all_active(), state, fn int, acc ->
        schedule_if_due(:video, int, acc, now, force)
      end)

    {state, :ok}
  end

  @doc """
  Determines if a check is due based on health state and current time.
  """
  @spec due_for_check?(Monitor.health_state(), DateTime.t()) :: boolean()
  def due_for_check?(%{last_check: nil}, _now), do: true

  def due_for_check?(%{last_check: last_check, backoff_ms: backoff_ms}, now) do
    next_time = DateTime.add(last_check, backoff_ms, :millisecond)
    DateTime.compare(next_time, now) != :gt
  end

  @doc """
  Calculates the next backoff duration for transient failures.
  Uses exponential backoff with a maximum cap.
  """
  @spec next_backoff_ms(pos_integer()) :: pos_integer()
  def next_backoff_ms(current) do
    current
    |> max(@check_interval)
    |> Kernel.*(2)
    |> min(@max_backoff)
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

  defp schedule_if_due(type, integration, state, now, force) do
    health_state = Monitor.get_state(state, type, integration.id)

    if force || due_for_check?(health_state, now) do
      Logger.debug("Scheduling integration health check",
        type: type,
        integration_id: integration.id,
        provider: integration.provider,
        backoff_ms: health_state.backoff_ms,
        last_error_class: health_state.last_error_class
      )

      enqueue_if_allowed(type, integration.id)
    else
      Logger.debug("Skipping integration health check (backoff)",
        type: type,
        integration_id: integration.id,
        provider: integration.provider,
        backoff_ms: health_state.backoff_ms,
        last_error_class: health_state.last_error_class
      )
    end

    state
  end

  defp enqueue_if_allowed(type, integration_id) do
    # Check circuit breaker for backpressure
    if should_skip_due_to_circuit?(type, integration_id) do
      :ok
    else
      enqueue_job(type, integration_id)
    end
  end

  defp enqueue_job(type, integration_id) do
    # Use Oban's built-in unique job constraints to prevent duplicates
    job =
      IntegrationHealthWorker.new(
        %{
          "type" => Atom.to_string(type),
          "integration_id" => integration_id
        },
        scheduled_at: scheduled_at_with_jitter(),
        unique: [
          period: div(@check_interval, 1000),
          keys: [:type, :integration_id],
          states: [:available, :scheduled, :retryable, :executing]
        ]
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

  defp should_skip_due_to_circuit?(type, integration_id) do
    integration_result =
      case type do
        :calendar -> CalendarIntegrationQueries.get(integration_id)
        :video -> VideoIntegrationQueries.get(integration_id)
      end

    case integration_result do
      {:ok, integration} ->
        provider_atom = safe_to_existing_atom(integration.provider)

        if provider_atom do
          check_circuit_breaker(type, integration, provider_atom)
        else
          false
        end

      {:error, :not_found} ->
        Logger.debug("Integration not found, skipping enqueue",
          type: type,
          integration_id: integration_id
        )

        true
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

  defp safe_to_existing_atom("" = value) do
    Logger.warning("Empty provider name encountered", value: value)
    nil
  end

  defp safe_to_existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError ->
      Logger.warning("Provider name not recognized, check for typos",
        value: value,
        hint: "Valid providers: google, outlook, caldav, nextcloud, radicale, teams, etc."
      )

      nil
  end
end
