defmodule Tymeslot.Integrations.HealthCheck.Scheduler do
  @moduledoc """
  Domain: Intelligent Check Timing

  Decides which integrations are due a health check and enqueues one for
  each, skipping those whose circuit breaker is open and spreading the
  enqueued checks with jitter. Run every five minutes by
  `Tymeslot.Workers.IntegrationHealthSweepWorker`, so an integration is
  probed within five minutes of its backoff elapsing.
  """

  require Logger

  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.Shared.IntegrationTypes

  alias Tymeslot.Infrastructure.{
    CalendarCircuitBreaker,
    ErrorTracking,
    ProviderBreakers,
    VideoCircuitBreaker
  }

  alias Tymeslot.Integrations.HealthCheck.ProviderHelpers
  alias Tymeslot.Workers.IntegrationHealthWorker

  @max_jitter_ms 30_000

  # `force: true` treats every active integration as due.
  @end_of_time ~U[9999-12-31 23:59:59Z]

  @type integration_type :: :calendar | :video

  @doc """
  Enqueues a health check for every active integration whose check is due.

  Seeds a default health state for integrations that have none, reads the
  due ones in one query per kind, and removes health states whose
  integration is gone. `force: true` enqueues a check for every active
  integration regardless of backoff.

  Each due integration is enqueued with its own `Oban.insert/1`, because the
  worker's uniqueness (one pending check per integration) is enforced on a
  single insert and not by `Oban.insert_all/1` on this engine: a check still
  waiting out its jitter when the next sweep runs must not be doubled.
  """
  @spec schedule_all(keyword()) :: :ok
  def schedule_all(opts \\ []) do
    now = if Keyword.get(opts, :force, false), do: @end_of_time, else: Clock.utc_now()

    for kind <- IntegrationTypes.kinds() do
      IntegrationHealthStateQueries.seed_missing(kind)

      kind
      |> IntegrationHealthStateQueries.due(now)
      |> Enum.each(&schedule(kind, &1))
    end

    IntegrationHealthStateQueries.delete_orphaned()

    :ok
  end

  @doc """
  Creates a scheduled timestamp with random jitter to prevent thundering herd.
  """
  @spec scheduled_at_with_jitter() :: DateTime.t()
  def scheduled_at_with_jitter do
    jitter_ms = :rand.uniform(@max_jitter_ms + 1) - 1
    DateTime.add(Clock.utc_now(), jitter_ms, :millisecond)
  end

  # Private Functions

  # Isolated per row: an exception while scheduling one integration must not
  # abort the sweep for every integration after it.
  defp schedule(type, integration) do
    Logger.debug("Scheduling integration health check",
      type: type,
      integration_id: integration.id,
      provider: integration.provider
    )

    enqueue_if_allowed(type, integration)
  rescue
    e ->
      ErrorTracking.report_error(e, __STACKTRACE__, %{
        type: type,
        integration_id: integration.id,
        provider: integration.provider
      })
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

  # A host breaker starts with a server's first call and is reaped once idle,
  # so none exists for a server with no recent traffic, as after every boot.
  # It has recorded no failures: it is closed, not missing.
  defp unstarted_as_closed({:error, :breaker_not_found}, host)
       when is_binary(host) and host != "",
       do: %{status: :closed}

  defp unstarted_as_closed(status, _host), do: status

  defp check_circuit_breaker(type, integration, provider_atom) do
    # Self-hosted providers (the CalDAV family and Exchange for calendars,
    # MiroTalk for video) key their circuit breaker per host, so this must
    # check the same breaker their calls actually trip, or a tenant whose
    # host is down never gets skipped here.
    base_url = integration.base_url

    circuit_status =
      try do
        case type do
          :calendar ->
            {breaker_provider, host} = CalendarCircuitBreaker.breaker_key(provider_atom, base_url)
            breaker_provider |> CalendarCircuitBreaker.status(host) |> unstarted_as_closed(host)

          :video ->
            host = ProviderBreakers.host_from_base_url(base_url)
            provider_atom |> VideoCircuitBreaker.status(host) |> unstarted_as_closed(host)
        end
      rescue
        e ->
          Logger.error("Circuit breaker status check failed",
            type: type,
            provider: integration.provider,
            error: LogFormat.reason(e)
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
          status: LogFormat.reason(unknown)
        )

        false
    end
  end
end
