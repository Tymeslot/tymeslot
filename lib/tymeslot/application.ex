defmodule Tymeslot.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  alias Phoenix.PubSub
  alias Tymeslot.Infrastructure.Metrics
  alias Tymeslot.Integrations.Calendar.TokenRefreshJob
  alias Tymeslot.Integrations.{HealthCheck, Telemetry}
  alias Tymeslot.Integrations.Shared.Lock
  alias TymeslotWeb.Endpoint

  @impl Application
  def start(_type, _args) do
    validate_config!()
    Logger.info("Starting Tymeslot application")

    # Attach Oban's structured telemetry logger — emits job start/stop/exception
    # events with job_id, queue, worker, attempt, and duration_ms automatically.
    Oban.Telemetry.attach_default_logger(encode: false)

    # Set up telemetry handlers for metrics
    Metrics.setup_handlers()

    # Set up integration telemetry handlers
    Telemetry.attach_default_handlers()

    # Initialize shared email asset cache (ETS)
    # Note: This table is primarily for static assets like logo data URIs.
    # If used for dynamic data, consider adding a cleanup mechanism or using CacheStore.
    :ets.new(:tymeslot_email_assets, [:set, :public, :named_table, read_concurrency: true])

    # Base children that are always started
    base_children = [
      TymeslotWeb.Telemetry,
      Tymeslot.Repo,
      {DNSCluster, query: Application.get_env(:tymeslot, :dns_cluster_query) || :ignore},
      {PubSub, name: Tymeslot.PubSub},
      # Start the Finch HTTP client (used by Req for all HTTP requests)
      {Finch, name: Tymeslot.Finch},
      # Start token refresh lock manager
      {Lock, []},
      # Task Supervisor for async operations
      {Task.Supervisor, name: Tymeslot.TaskSupervisor}
    ]

    # Additional children for non-test environments
    production_children =
      if Application.get_env(:tymeslot, :environment) != :test do
        [
          # Start health check service
          HealthCheck,
          # Start dashboard cache GenServer
          Tymeslot.Infrastructure.DashboardCache,
          # Start availability cache GenServer
          Tymeslot.Infrastructure.AvailabilityCache,
          # Start webhook idempotency cache
          Tymeslot.Payments.Webhooks.IdempotencyCache,
          # Start calendar request coalescer
          Tymeslot.Integrations.Calendar.RequestCoalescer,
          # Start Oban for background job processing
          {Oban, oban_config()},
          # Start Hammer-backed rate limiter (ETS sliding window)
          {Tymeslot.Security.RateLimit, clean_period: :timer.minutes(5)},
          # Start account lockout tracker
          Tymeslot.Security.AccountLockout,
          # Start circuit breaker supervisor
          Tymeslot.Infrastructure.CircuitBreakerSupervisor
        ]
      else
        # Only start essential services for tests
        [
          # Start dashboard cache GenServer
          Tymeslot.Infrastructure.DashboardCache,
          # Start availability cache GenServer
          Tymeslot.Infrastructure.AvailabilityCache,
          # Start webhook idempotency cache
          Tymeslot.Payments.Webhooks.IdempotencyCache,
          # Start Hammer-backed rate limiter (ETS sliding window)
          {Tymeslot.Security.RateLimit, clean_period: :timer.minutes(5)},
          # Start account lockout tracker
          Tymeslot.Security.AccountLockout,
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

  defp validate_config! do
    # Validate mailer configuration at startup
    # This catches SMTP misconfigurations before first email send
    # Note: Always returns :ok but logs prominent errors if misconfigured
    mailer_config = Application.get_env(:tymeslot, Tymeslot.Mailer)
    Tymeslot.Mailer.HealthCheck.validate_startup_config(mailer_config)

    # Validate legal agreements configuration
    if Application.get_env(:tymeslot, :enforce_legal_agreements, false) do
      terms = Application.get_env(:tymeslot, :legal_terms_url)
      privacy = Application.get_env(:tymeslot, :legal_privacy_url)

      if is_nil(terms) or is_nil(privacy) do
        Logger.warning("""
        LEGAL AGREEMENTS ENFORCED BUT PATHS MISSING:
        :enforce_legal_agreements is set to true, but :legal_terms_url or :legal_privacy_url is nil.
        Users will not be able to complete registration successfully if these pages are unreachable.
        """)
      end
    end

    # Log HTTP proxy configuration if enabled
    log_proxy_config()

    # Validate Oban Cron plugin configuration for critical workers (skip in test)
    if Application.get_env(:tymeslot, :environment) != :test do
      validate_oban_cron_config!()
    end

    # Validate database connection pool configuration
    validate_db_pool_config!()
  end

  # Logs HTTP proxy configuration for visibility
  defp log_proxy_config do
    case Application.get_env(:tymeslot, :http_proxy) do
      nil ->
        Logger.info("HTTP/HTTPS Proxy: Not configured (using direct connections)")
        :ok

      config ->
        http_info =
          case config.http_proxy do
            nil ->
              "Not configured"

            %{host: host, port: port, auth: auth} ->
              auth_status = if auth, do: " (authenticated)", else: ""
              "#{host}:#{port}#{auth_status}"
          end

        https_info =
          case config.https_proxy do
            nil ->
              "Not configured"

            %{host: host, port: port, auth: auth} ->
              auth_status = if auth, do: " (authenticated)", else: ""
              "#{host}:#{port}#{auth_status}"
          end

        no_proxy_info =
          if config.no_proxy == [] do
            "None"
          else
            Enum.join(config.no_proxy, ", ")
          end

        Logger.info("""
        HTTP/HTTPS PROXY CONFIGURED FOR OUTBOUND REQUESTS:
        HTTP Proxy:  #{http_info}
        HTTPS Proxy: #{https_info}
        NO_PROXY:    #{no_proxy_info}
        """)

        :ok
    end
  end

  # Validates that Oban Cron plugin is configured with critical maintenance workers
  defp validate_oban_cron_config! do
    oban_config = Application.get_env(:tymeslot, Oban, [])
    plugins = Keyword.get(oban_config, :plugins, [])

    # Find the Cron plugin configuration
    cron_plugin =
      Enum.find(plugins, fn
        {Oban.Plugins.Cron, _opts} -> true
        _other -> false
      end)

    case cron_plugin do
      nil ->
        Logger.warning("""
        OBAN CRON PLUGIN NOT CONFIGURED:
        Oban.Plugins.Cron is not configured in Oban plugins.
        Critical maintenance workers (ObanMaintenanceWorker, ObanQueueMonitorWorker) will not run.
        This can lead to job accumulation and system degradation.
        Add Oban.Plugins.Cron to your Oban config with required cron jobs.
        """)

      {Oban.Plugins.Cron, opts} ->
        crontab = Keyword.get(opts, :crontab, [])

        # Check for critical workers in crontab
        critical_workers = [
          Tymeslot.Workers.ObanMaintenanceWorker,
          Tymeslot.Workers.ObanQueueMonitorWorker
        ]

        Enum.each(critical_workers, fn worker ->
          worker_configured? =
            Enum.any?(crontab, fn
              {_schedule, ^worker} -> true
              {_schedule, ^worker, _opts} -> true
              _other -> false
            end)

          unless worker_configured? do
            Logger.warning(
              "Critical Oban worker not scheduled in Cron plugin: #{inspect(worker)}. " <>
                "This worker should run periodically for system health."
            )
          end
        end)
    end

    :ok
  end

  # Validates database connection pool size against database max_connections
  defp validate_db_pool_config! do
    repo_config = Application.get_env(:tymeslot, Tymeslot.Repo, [])
    pool_size = Keyword.get(repo_config, :pool_size, 10)

    # Calculate theoretical max connections from Oban queues
    base_queues = Application.get_env(:tymeslot, :oban_queues, [])
    additional_queues = Application.get_env(:tymeslot, :oban_additional_queues, [])
    merged_queues = Keyword.merge(base_queues, additional_queues)

    max_oban_concurrency =
      merged_queues
      |> Keyword.values()
      |> Enum.sum()

    # Warn if pool_size is high relative to typical Postgres max_connections
    # Default Postgres max_connections is often 100
    # Docker embedded Postgres typically uses max_connections=100
    if pool_size >= 60 do
      Logger.info("""
      HIGH DATABASE CONNECTION POOL SIZE: #{pool_size}
      With Oban max concurrency of #{max_oban_concurrency}, you may use up to #{pool_size} connections.
      Ensure your PostgreSQL max_connections is configured appropriately (recommend >= #{pool_size + 40}).

      For Docker deployments, the embedded Postgres uses max_connections=100 by default.
      For production, consider increasing max_connections in postgresql.conf if needed.

      To check your database's max_connections:
        SELECT current_setting('max_connections');
      """)
    end

    :ok
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl Application
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
    base_config = Application.get_env(:tymeslot, Oban) || [repo: Tymeslot.Repo]

    # Read queues at runtime (they can't be read at config time)
    # Base queue configuration from Core
    base_queues = Application.get_env(:tymeslot, :oban_queues, [])
    # Additional queues can be provided via this extension point (e.g., by wrapper applications)
    additional_queues = Application.get_env(:tymeslot, :oban_additional_queues, [])

    # Validate types before processing
    unless Keyword.keyword?(base_queues) do
      raise ArgumentError,
            ":oban_queues must be a keyword list, got: #{inspect(base_queues)}"
    end

    unless Keyword.keyword?(additional_queues) do
      raise ArgumentError,
            ":oban_additional_queues must be a keyword list, got: #{inspect(additional_queues)}"
    end

    # Log if additional queues override base queue concurrency
    base_queue_keys = Keyword.keys(base_queues)
    additional_queue_keys = Keyword.keys(additional_queues)
    conflict_keys = Enum.filter(additional_queue_keys, &(&1 in base_queue_keys))

    if conflict_keys != [] do
      Logger.info("Additional queues overriding Core queue concurrency", queues: conflict_keys)
    end

    # Validate queue configurations before merging
    validate_queue_config!(base_queues, "base")
    validate_queue_config!(additional_queues, "additional")

    # Merge queue configurations (additional takes precedence for conflicts)
    merged_queues = Keyword.merge(base_queues, additional_queues)

    # Validate that we have at least one queue configured
    final_queues =
      if Enum.empty?(merged_queues) do
        Logger.error("No Oban queues configured, using minimal default")
        [default: 1]
      else
        merged_queues
      end

    # Merge queues into the base config
    Keyword.put(base_config, :queues, final_queues)
  end

  # Validates Oban queue configuration
  @spec validate_queue_config!(keyword(), String.t()) :: :ok
  defp validate_queue_config!(queues, source) do
    # Get pool size for validation
    repo_config = Application.get_env(:tymeslot, Tymeslot.Repo, [])
    pool_size = Keyword.get(repo_config, :pool_size, 10)

    Enum.each(queues, fn {queue, concurrency} ->
      cond do
        not is_atom(queue) ->
          raise ArgumentError,
                "Invalid queue name in #{source} queues: #{inspect(queue)} (must be an atom)"

        not is_integer(concurrency) ->
          raise ArgumentError,
                "Invalid concurrency for queue #{queue} in #{source} queues: " <>
                  "#{inspect(concurrency)} (must be an integer)"

        concurrency <= 0 ->
          raise ArgumentError,
                "Invalid concurrency for queue #{queue} in #{source} queues: " <>
                  "#{concurrency} (must be positive)"

        concurrency > pool_size ->
          raise ArgumentError,
                "Queue #{queue} concurrency (#{concurrency}) exceeds pool_size (#{pool_size}). " <>
                  "Queue concurrency cannot be higher than the database connection pool size."

        concurrency >= 100 ->
          Logger.warning(
            "Very high concurrency for queue #{queue} in #{source} queues: #{concurrency}. " <>
              "Ensure this is intentional and pool_size can support it.",
            queue: queue,
            concurrency: concurrency,
            pool_size: pool_size,
            source: source
          )

        true ->
          :ok
      end
    end)

    :ok
  end

  # Schedule periodic jobs
  @spec schedule_periodic_jobs() :: :ok
  defp schedule_periodic_jobs do
    # Schedule Google Calendar token refresh job to run every hour
    Task.start(fn ->
      TokenRefreshJob.schedule_periodic_refresh()
    end)

    Logger.info("Scheduled periodic Google Calendar token refresh job")

    # Note: Oban maintenance and queue monitoring workers are now scheduled via
    # Oban.Plugins.Cron (see config files). Manual scheduling is no longer needed.
    :ok
  end
end
