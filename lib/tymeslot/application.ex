defmodule Tymeslot.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  alias Phoenix.PubSub
  alias Tymeslot.Analytics.Telemetry, as: AnalyticsTelemetry
  alias Tymeslot.AppSettings
  alias Tymeslot.Auth.AdminBootstrap

  alias Tymeslot.Infrastructure.{
    CrashReporter,
    Metrics,
    ObanFailureAlerter,
    ObanLogger,
    ObanQueues
  }

  alias Tymeslot.Infrastructure.Logging.{FileSink, MetadataRedactor}
  alias Tymeslot.Integrations.Calendar.TokenRefreshJob
  alias Tymeslot.Integrations.{HealthCheck, Telemetry}
  alias Tymeslot.Integrations.Shared.Lock
  alias Tymeslot.Mailer.HealthCheck, as: MailerHealthCheck
  alias Tymeslot.Telegram.BotSetup
  alias TymeslotWeb.Endpoint

  @impl Application
  def start(_type, _args) do
    validate_config!()

    # Install the global Logger metadata redactor before the first log line
    # so any sensitive keys (api_key, token, secret, ...) passed inline are
    # scrubbed at every handler.
    MetadataRedactor.attach()

    # Attach the rotating-file sink (no-op when LOG_FILE_PATH is unset on
    # non-cloudron deployments). Stdout output is unaffected.
    FileSink.attach()

    Logger.info("Starting Tymeslot application")

    # Oban's default logger handles non-job events (plugin, notifier, peer,
    # queue, stager). Job events are owned by ObanLogger instead, so every job
    # log line carries a correlation_id and failures surface at :warning/:error
    # rather than being buried at :info.
    Oban.Telemetry.attach_default_logger(
      encode: false,
      events: [:notifier, :peer, :plugin, :queue, :stager]
    )

    # Emit job start/stop/exception logs with correlation_id and failure-aware
    # levels for every Oban job process.
    ObanLogger.attach()

    # Raise an admin alert when a job fails permanently (exhausts its retries).
    ObanFailureAlerter.attach()

    # Set up telemetry handlers for metrics
    Metrics.setup_handlers()

    # Set up integration telemetry handlers
    Telemetry.attach_default_handlers()

    # Surface dropped/failed booking-analytics page-view writes in the logs.
    AnalyticsTelemetry.attach_default_handler()

    # Base children that are always started
    base_children = [
      TymeslotWeb.Telemetry,
      Tymeslot.Repo,
      {DNSCluster, query: Application.get_env(:tymeslot, :dns_cluster_query) || :ignore},
      {PubSub, name: Tymeslot.PubSub},
      # Start the Finch HTTP client (used by Req for all HTTP requests).
      {Finch, name: Tymeslot.Finch, pools: %{default: finch_default_pool()}},
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
          # Start booking-analytics dashboard cache
          Tymeslot.Analytics.MetricsCache,
          # Start calendar discovery cache
          Tymeslot.Integrations.Calendar.Shared.DiscoveryCache,
          # Start calendar request coalescer
          Tymeslot.Integrations.Calendar.RequestCoalescer,
          # Start Oban for background job processing
          {Oban, oban_config()},
          # Start Hammer-backed rate limiter (ETS sliding window)
          {Tymeslot.Security.RateLimit, clean_period: :timer.minutes(5)},
          # Own the account lockout ETS table (AccountLockout is a plain module)
          Tymeslot.Security.AccountLockout.TableOwner,
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
          # Start booking-analytics dashboard cache (ETS table needed in tests too)
          Tymeslot.Analytics.MetricsCache,
          # Start calendar discovery cache (ETS table needed in tests too)
          Tymeslot.Integrations.Calendar.Shared.DiscoveryCache,
          # Start Hammer-backed rate limiter (ETS sliding window)
          {Tymeslot.Security.RateLimit, clean_period: :timer.minutes(5)},
          # Own the account lockout ETS table (AccountLockout is a plain module)
          Tymeslot.Security.AccountLockout.TableOwner,
          # Start Oban for background job processing (in manual mode for tests)
          {Oban, oban_config()},
          # Start circuit breaker supervisor (needed for some tests)
          Tymeslot.Infrastructure.CircuitBreakerSupervisor,
          # Start calendar request coalescer (needed for calendar tests)
          Tymeslot.Integrations.Calendar.RequestCoalescer
        ]
      end

    # Interactive dev calendar rule store. Started only when opted in via
    # config/dev.exs (DEV_CALENDAR / DEV_EMPTY_CALENDAR); the module is compiled
    # solely under dev/support, so this never runs in test or release builds.
    dev_children =
      if Application.get_env(:tymeslot, :dev_calendar_enabled, false),
        do: [Tymeslot.Integrations.Calendar.DebugStore],
        else: []

    children =
      base_children ++
        production_children ++
        dev_children ++
        tz_watcher_children() ++ [TymeslotWeb.Endpoint] ++ mailer_health_check_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Tymeslot.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("Tymeslot application started successfully", pid: inspect(pid))

        # Apply DB-backed admin overrides on top of config-layer values.
        # Must run after Repo is started; safe in test mode (the singleton row
        # has all nils on a fresh test DB, so load!/0 is effectively a no-op).
        AppSettings.load!()

        # Forward every unhandled process crash (web, LiveView, GenServer, Task)
        # to AdminAlerts. Attached only after the supervision tree is up, since
        # the handler depends on Tymeslot.Security.RateLimit (ETS) and
        # Tymeslot.TaskSupervisor. Skipped in test, where intentionally-crashed
        # processes would otherwise generate alert noise; tests attach it
        # explicitly. Also skipped when admin alerts are disabled — the handler's
        # only purpose is forwarding to AdminAlerts, so attaching it when alerts
        # are off wastes per-crash work (rate-limit ETS writes, task spawns,
        # formatting) and emits spurious "ADMIN ALERT" log lines.
        if Application.get_env(:tymeslot, :environment) != :test do
          if Application.get_env(:tymeslot, :admin_alerts_enabled, false) do
            CrashReporter.attach()
          end

          schedule_periodic_jobs()
          AdminBootstrap.warn_if_orphaned_install()
        end

        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("Failed to start Tymeslot application", reason: inspect(reason))
        error
    end
  end

  # Connection pool for all outbound HTTP (Req → Finch). `size`/`count` are read
  # from config so deployments with more headroom (SaaS) can run a larger per-host
  # pool than a small self-hosted Core box; the defaults below are the safe Core
  # values and SaaS overrides them via `config :tymeslot, :finch_default_pool`.
  #
  # `conn_max_idle_time` (NOT `pool_max_idle_time`) evicts individual connections
  # the remote silently closed after its keep-alive timeout, preventing "socket
  # closed" errors. `pool_max_idle_time` would instead tear the whole pool down
  # when idle and churn pool restarts — surfacing as transient
  # `:pool_not_available` errors when traffic resumes — so it is left at its
  # `:infinity` default. `conn_opts` caps the TCP connect handshake at 10s,
  # preventing OS-level TCP timeouts (75-120s) from dominating when an endpoint
  # is unreachable.
  defp finch_default_pool do
    [size: 50, count: 1, conn_max_idle_time: 30_000]
    |> Keyword.merge(Application.get_env(:tymeslot, :finch_default_pool, []))
    |> Keyword.put(:conn_opts, timeout: 10_000)
  end

  defp validate_config! do
    # Mailer configuration is validated by mailer_health_check_children/0
    # instead of here: its credential probe needs Tymeslot.Finch, which
    # doesn't exist yet at this point in start/2, before Supervisor.start_link
    # has run.

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

  # Runs the mailer startup health check as a supervised, transient Task
  # appended after Tymeslot.Finch (and every other child) so its credential
  # probe — which requires the Finch pool to be up — actually executes,
  # instead of always taking the "Finch not started" skip branch. Skipped in
  # test, mirroring the gating already used for the other startup-only checks
  # in validate_config!/0. `:transient` stops the supervisor restarting the
  # task once it exits normally; HealthCheck never raises, so it always does.
  @spec mailer_health_check_children() :: [Supervisor.child_spec()]
  defp mailer_health_check_children do
    if Application.get_env(:tymeslot, :environment) != :test do
      [
        Supervisor.child_spec(
          {Task, &validate_mailer_config!/0},
          id: Tymeslot.Mailer.HealthCheckTask,
          restart: :transient
        )
      ]
    else
      []
    end
  end

  # The IANA time zone database is pinned to a vendored release (see
  # `config :tz, :iana_version`), so nothing tells us a newer one exists unless
  # we ask. This watcher only logs a warning when data.iana.org publishes a
  # release newer than the one compiled in; it never downloads or recompiles,
  # which would fail on a read-only release filesystem anyway. Off by default so
  # dev and test make no outbound calls; `config/prod.exs` turns it on.
  @spec tz_watcher_children() :: [{module(), keyword()}]
  defp tz_watcher_children do
    if Application.get_env(:tymeslot, :tz_watch_enabled, false) do
      [{Tz.WatchPeriodically, interval_in_days: 7}]
    else
      []
    end
  end

  @spec validate_mailer_config!() :: :ok
  defp validate_mailer_config! do
    mailer_config = Application.get_env(:tymeslot, Tymeslot.Mailer)
    MailerHealthCheck.validate_startup_config(mailer_config)
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

        Logger.info("HTTP/HTTPS proxy configured for outbound requests",
          http_proxy: http_info,
          https_proxy: https_info,
          no_proxy: no_proxy_info
        )

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
      Logger.info("High database connection pool size detected",
        pool_size: pool_size,
        max_oban_concurrency: max_oban_concurrency,
        recommended_min_connections: pool_size + 40
      )
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

  # Configuration function for Oban. Queues are read and validated at runtime;
  # they can't be resolved at config time.
  @spec oban_config() :: keyword()
  defp oban_config do
    base_config = Application.get_env(:tymeslot, Oban) || [repo: Tymeslot.Repo]

    ObanQueues.build(base_config)
  end

  # Schedule periodic jobs using TaskSupervisor for proper error handling
  @spec schedule_periodic_jobs() :: :ok
  defp schedule_periodic_jobs do
    schedule_supervised("Google Calendar token refresh", fn ->
      TokenRefreshJob.schedule_periodic_refresh()
    end)

    # Register Telegram webhook if shared bot mode is enabled (production only —
    # localhost is not reachable by Telegram's servers in dev/test)
    if Application.get_env(:tymeslot, :telegram_shared_bot, false) and
         Application.get_env(:tymeslot, :environment) == :prod do
      schedule_supervised("Telegram webhook registration", fn ->
        BotSetup.register_webhook()
      end)
    end

    :ok
  end

  defp schedule_supervised(name, fun) do
    case Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fun) do
      {:ok, _pid} ->
        Logger.info("Scheduled post-startup task", task: name)

      {:error, reason} ->
        Logger.error("Failed to schedule post-startup task",
          task: name,
          reason: inspect(reason)
        )
    end
  end
end
