defmodule Tymeslot.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  alias Phoenix.PubSub
  alias Tymeslot.Infrastructure.{ConnectionPool, Metrics}
  alias Tymeslot.Integrations.Calendar.Auth.TokenRefreshLock
  alias Tymeslot.Integrations.Calendar.TokenRefreshJob
  alias Tymeslot.Integrations.{HealthCheck, Telemetry}
  alias Tymeslot.Workers.ObanMaintenanceWorker
  alias TymeslotWeb.Endpoint

  @impl true
  def start(_type, _args) do
    Logger.info("Starting Tymeslot application")

    # Set up connection pools before starting other services
    ConnectionPool.setup_pools()

    # Set up telemetry handlers for metrics
    Metrics.setup_handlers()

    # Set up integration telemetry handlers
    Telemetry.attach_default_handlers()

    # Base children that are always started
    base_children = [
      TymeslotWeb.Telemetry,
      Tymeslot.Repo,
      {DNSCluster, query: Application.get_env(:tymeslot, :dns_cluster_query) || :ignore},
      {PubSub, name: Tymeslot.PubSub},
      # Start the Finch HTTP client for sending emails and external HTTP calls
      {Finch, name: Tymeslot.Finch},
      # Start token refresh lock manager
      {TokenRefreshLock, []}
    ]

    # Additional children for non-test environments
    production_children =
      if Application.get_env(:tymeslot, :environment) != :test do
        [
          # Start health check service
          HealthCheck,
          # Start dashboard cache GenServer
          Tymeslot.Infrastructure.DashboardCache,
          # Start calendar request coalescer
          Tymeslot.Integrations.Calendar.RequestCoalescer,
          # Start Oban for background job processing
          {Oban, oban_config()},
          # Start custom rate limiter
          Tymeslot.Security.RateLimiter,
          # Start account lockout tracker
          Tymeslot.Security.AccountLockout,
          # Start circuit breaker supervisor
          Tymeslot.Infrastructure.CircuitBreakerSupervisor
        ]
      else
        # Only start essential services for tests
        [
          # Start Oban for background job processing (in manual mode for tests)
          {Oban, oban_config()},
          # Start circuit breaker supervisor (needed for some tests)
          Tymeslot.Infrastructure.CircuitBreakerSupervisor,
          # Start calendar request coalescer (needed for calendar tests)
          Tymeslot.Integrations.Calendar.RequestCoalescer
        ]
      end

    # Always end with the endpoint
    children = base_children ++ production_children ++ [TymeslotWeb.Endpoint]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Tymeslot.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("Tymeslot application started successfully", pid: inspect(pid))

        # Schedule periodic jobs after application startup (only in non-test environments)
        if Application.get_env(:tymeslot, :environment) != :test do
          schedule_periodic_jobs()
        end

        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("Failed to start Tymeslot application", reason: inspect(reason))
        error
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    Logger.info("Application configuration changed",
      changed: inspect(changed),
      removed: inspect(removed)
    )

    Endpoint.config_change(changed, removed)
    :ok
  end

  # Configuration function for Oban
  @spec oban_config() :: keyword()
  defp oban_config do
    Application.get_env(:tymeslot, Oban) || [repo: Tymeslot.Repo]
  end

  # Schedule periodic jobs
  @spec schedule_periodic_jobs() :: :ok
  defp schedule_periodic_jobs do
    # Schedule Google Calendar token refresh job to run every hour
    Task.start(fn ->
      TokenRefreshJob.schedule_periodic_refresh()
    end)

    Logger.info("Scheduled periodic Google Calendar token refresh job")

    # Schedule Oban maintenance worker
    Task.start(fn ->
      ObanMaintenanceWorker.start_if_not_scheduled()
    end)

    Logger.info("Scheduled Oban maintenance worker")
    :ok
  end
end
