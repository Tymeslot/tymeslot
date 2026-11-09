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
  alias Tymeslot.CalendarGrid.WriteGuardianSupervisor

  alias Tymeslot.Infrastructure.{
    AdminAlerts,
    CrashReporter,
    FinchPool,
    IndexHealth,
    Metrics,
    ObanCron,
    ObanEngine,
    ObanLogger,
    ObanQueues,
    ObanRescue,
    PoolPressureMonitor,
    ProxyConfig,
    ProxyCredentials,
    Tasks
  }

  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Infrastructure.ErrorTracking.Alerter, as: ErrorAlerter
  alias Tymeslot.Infrastructure.ErrorTracking.ObanOutcomes
  alias Tymeslot.Infrastructure.ErrorTracking.ReasonScrubber
  alias Tymeslot.Infrastructure.ErrorTracking.SafeIntegrations
  alias Tymeslot.Infrastructure.ErrorTracking.Throttle
  alias Tymeslot.Infrastructure.Logging.{FileSink, LogFormat, MetadataRedactor}
  alias Tymeslot.Integrations.HealthCheck.Alerting
  alias Tymeslot.Integrations.Shared.Lock
  alias Tymeslot.Integrations.Telemetry
  alias Tymeslot.Mailer.HealthCheck, as: MailerHealthCheck
  alias Tymeslot.Payments.Webhooks.SecretCheck
  alias Tymeslot.Security.CredentialReencryption.KeyReport
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Telegram.BotSetup
  alias Tymeslot.Workers.ErrorTrackerMaintenanceWorker
  alias TymeslotWeb.Endpoint
  alias TymeslotWeb.Plugs.AdditionalDashboardPlugs
  alias TymeslotWeb.Router

  # Children the test environment does without: periodic schedulers whose
  # timers would fire into unrelated tests.
  @not_started_in_test [PoolPressureMonitor]

  @impl Application
  def start(_type, _args) do
    # Checked before anything else, so that an unusable key stops the boot
    # with a log line saying how to fix it rather than a crash report.
    case Encryption.check_config() do
      :ok -> start_application()
      {:error, error} -> {:error, {:invalid_encryption_config, error.reason}}
    end
  end

  defp start_application do
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

    attach_error_tracking()

    # Set up telemetry handlers for metrics
    Metrics.setup_handlers()

    # Set up integration telemetry handlers
    Telemetry.attach_default_handlers()

    # Surface dropped/failed booking-analytics page-view writes in the logs.
    AnalyticsTelemetry.attach_default_handler()

    test? = Application.get_env(:tymeslot, :environment) == :test

    # Base children that are always started
    base_children = [
      TymeslotWeb.Telemetry,
      # Per-fingerprint cap on stored error occurrences; before the Repo so
      # that no report can reach the database unthrottled once it is up.
      Throttle,
      Tymeslot.Repo,
      # Apply DB-backed admin overrides on top of config-layer values before
      # anything that serves requests or runs jobs starts.
      AppSettings.loader_child_spec(),
      {DNSCluster, query: Application.get_env(:tymeslot, :dns_cluster_query) || :ignore},
      {PubSub, name: Tymeslot.PubSub},
      # Start the Finch HTTP client (used by Req for all HTTP requests).
      {Finch, name: Tymeslot.Finch, pools: %{default: FinchPool.default_options()}},
      # Stops the per-destination pools pinned requests leave behind
      FinchPool.Janitor,
      # Start token refresh lock manager
      {Lock, []},
      # Task Supervisor for async operations
      {Task.Supervisor, name: Tymeslot.TaskSupervisor},
      # Bounded, so a crash storm cannot spawn one database writer per crash
      {Task.Supervisor,
       name: ErrorTracking.task_supervisor(),
       max_children: Application.get_env(:tymeslot, :error_tracking_max_concurrent_reports, 10)}
    ]

    # Services the request path and background jobs both rely on. One list
    # for every environment, so the order tests run against is the order
    # production starts in; the few children tests do without are filtered
    # out below rather than kept in a second hand-maintained list.
    #
    # Oban comes after everything its jobs call (caches, the rate limiter,
    # the circuit breakers): its queues start fetching during its own init,
    # and children stop in reverse order, so placed here it starts after them
    # and stops before them, and no job runs against a dependency that is
    # not up.
    service_children =
      Enum.reject(
        [
          Tymeslot.Infrastructure.DashboardCache,
          Tymeslot.Infrastructure.AvailabilityCache,
          # Webhook idempotency cache
          Tymeslot.Payments.Webhooks.IdempotencyCache,
          # Booking-analytics dashboard cache
          Tymeslot.Analytics.MetricsCache,
          Tymeslot.Integrations.Calendar.Shared.DiscoveryCache,
          Tymeslot.Integrations.Calendar.Runtime.RequestCoalescer,
          # Rate limiter (sliding log in ETS)
          {Tymeslot.Security.RateLimit, clean_period: :timer.minutes(5)},
          Tymeslot.Infrastructure.CircuitBreakerSupervisor,
          # Background jobs (manual testing mode in tests)
          {Oban, oban_config()},
          # Alert when queries keep waiting for a database connection
          PoolPressureMonitor
        ],
        &(test? and &1 in @not_started_in_test)
      )

    # Interactive dev calendar rule store. Started only when opted in via
    # config/dev.exs (DEV_CALENDAR / DEV_EMPTY_CALENDAR); the module is compiled
    # solely under dev/support, so this never runs in test or release builds.
    dev_children =
      if Application.get_env(:tymeslot, :dev_calendar_enabled, false),
        do: [Tymeslot.Integrations.Calendar.DebugStore],
        else: []

    children =
      base_children ++
        service_children ++
        dev_children ++
        [
          # Guardians that finish the calendar grid's queued writes when the
          # grid's LiveView is gone. Children stop in reverse order, so placed
          # here they stop right after the Endpoint: the LiveViews it takes
          # down hand their queues to guardians that can still reach the
          # circuit breakers, Oban and the caches, and on stopping save what
          # is left for a later sync. Started any earlier, they would drive
          # the queue against stopped breakers and lose it.
          WriteGuardianSupervisor,
          TymeslotWeb.Endpoint
        ] ++ startup_check_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Tymeslot.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("Tymeslot application started successfully", pid: LogFormat.reason(pid))

        if Application.get_env(:tymeslot, :environment) != :test do
          check_deployment_config()
          schedule_periodic_jobs()
          AdminBootstrap.warn_if_orphaned_install()
        end

        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("Failed to start Tymeslot application", reason: LogFormat.reason(reason))
        error
    end
  end

  defp attach_error_tracking do
    # Raise an admin alert when ErrorTracker records a new error, or a
    # resolved one happens again, wherever it was raised (request, LiveView,
    # job or crashed process).
    ErrorAlerter.attach()

    # ErrorTracker's own integrations write to the database from telemetry
    # handlers, and telemetry detaches a handler that raises: one failed
    # write would stop exception recording until the next restart. Replace
    # them with handlers that log such a failure and stay attached.
    SafeIntegrations.install()

    # Mask email addresses and credentials in the exception messages
    # ErrorTracker stores, which its context Filter does not reach.
    ReasonScrubber.attach()

    # Both skipped in test, where deliberately crashed processes and jobs
    # that discard on purpose would otherwise be recorded; tests attach them
    # explicitly.
    if Application.get_env(:tymeslot, :environment) != :test do
      # Record every process crash ErrorTracker's integrations do not see
      # (GenServers, Tasks, bare processes). Attached before the supervision
      # tree starts, so a child crashing on boot is recorded. The handler
      # offloads to the bounded ErrorTracking.TaskSupervisor, started among
      # the first children after the Repo; a crash before that, or while all
      # its tasks are busy, is dropped, never raised. It reads ErrorTracker's
      # `enabled` switch on every crash, so switching error tracking off
      # stops it without a restart.
      CrashReporter.attach()

      # Record jobs a worker discards or cancels, and alert on jobs the
      # Lifeline discards. Oban starts inside the tree, so attaching first
      # misses nothing.
      ObanOutcomes.attach()
    end
  end

  # Checks that read DB-backed settings, so they run after AppSettings.load!/0.
  defp check_deployment_config do
    # A recipient set only in the admin settings counts.
    AdminAlerts.check_config()

    # Meeting payments can be switched on in the admin settings, which is what
    # makes the Connect webhook secret required.
    _missing = SecretCheck.check()

    # A variable set to a value it does not recognise fixes nothing.
    AppSettings.warn_unrecognised_env_values()

    # A variable outranks what an admin saved, so an old `.env` line can
    # silently undo it.
    AppSettings.warn_pins_overriding_saved_values()

    # A variable fixing a sign-in setting can lock every admin out.
    AppSettings.warn_if_pins_block_sign_in()
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

    # Validate the Oban configuration: the critical cron workers are scheduled,
    # and an abandoned job can still be rescued (skip in test)
    if Application.get_env(:tymeslot, :environment) != :test do
      oban_config = Application.get_env(:tymeslot, Oban, [])

      # Checked as Oban will run it, with the crontab filled in.
      oban_config |> ObanCron.extend() |> ObanCron.warn_on_missing_workers()
      ObanRescue.warn_on_unsafe_lifeline(oban_config)
    end

    # Validate database connection pool configuration
    validate_db_pool_config!()

    # The additional dashboard hooks and plugs are deployment gates: refuse to
    # start with one that could not run, rather than failing at first use.
    Router.validate_additional_hooks!()
    AdditionalDashboardPlugs.validate_config!()

    # The integration health alert thresholds are read by an hourly job; a
    # value it cannot run on is refused here rather than at every run.
    Alerting.validate_config!()
  end

  # The startup checks that only work once the rest of the tree is up: the
  # mailer credential probe needs Tymeslot.Finch, the invalid-index report and
  # the retired-key check need Tymeslot.Repo. All are supervised tasks appended
  # after every other child for that reason, and all are skipped in test.
  @spec startup_check_children() :: [Supervisor.child_spec()]
  defp startup_check_children do
    mailer_health_check_children() ++ index_health_children() ++ key_check_children()
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

  # Reports indexes PostgreSQL has marked invalid, which is how an interrupted
  # `CREATE INDEX CONCURRENTLY` leaves a migration's index behind: silently
  # unused by the planner, and never rebuilt because the replayed migration's
  # `IF NOT EXISTS` sees the name and skips. See `IndexHealth`.
  #
  # A supervised task rather than a call in `start/2`, so a slow or unreachable
  # database delays nothing on the boot path, and `:temporary` rather than
  # `:transient`, so a crash is never retried: this is a diagnostic, and a
  # diagnostic must not be able to take the application down with it. Skipped
  # in test, like every other startup-only check here; the test suite drives
  # `IndexHealth.check/0` directly.
  @spec index_health_children() :: [Supervisor.child_spec()]
  defp index_health_children do
    if Application.get_env(:tymeslot, :environment) != :test do
      [
        Supervisor.child_spec(
          {Task, &IndexHealth.check/0},
          id: Tymeslot.Infrastructure.IndexHealthTask,
          restart: :temporary
        )
      ]
    else
      []
    end
  end

  # Logs an error when stored values sit under a key id the keyring no longer
  # lists, or, with LEGACY_KEY_RETIRED set, under no configured key at all
  # (see `KeyReport`). Off the boot path and `:temporary`, like
  # `index_health_children/0`: the check reads every encrypted column, and a
  # diagnostic never delays or takes down the application. Skipped in test,
  # which drives the check directly.
  @spec key_check_children() :: [Supervisor.child_spec()]
  defp key_check_children do
    if Application.get_env(:tymeslot, :environment) != :test do
      [
        Supervisor.child_spec(
          {Task, &KeyReport.warn_about_unreadable_values/0},
          id: Tymeslot.Security.KeyCheckTask,
          restart: :temporary
        )
      ]
    else
      []
    end
  end

  @spec validate_mailer_config!() :: :ok
  defp validate_mailer_config! do
    mailer_config = Application.get_env(:tymeslot, Tymeslot.Mailer)
    MailerHealthCheck.validate_startup_config(mailer_config)
  end

  # Logs HTTP proxy configuration for visibility.
  #
  # Read through `ProxyConfig.load/0` rather than `Application.get_env/2`, so
  # the credentials this function reaches are always the normalised struct that
  # refuses to print its password, whatever shape was put in the application
  # environment. Nothing here prints them today; going through the one boundary
  # is what keeps that true if this ever grows a fuller dump.
  defp log_proxy_config do
    case ProxyConfig.load() do
      nil ->
        Logger.info("HTTP/HTTPS Proxy: Not configured (using direct connections)")
        :ok

      config ->
        http_info = format_proxy_endpoint(config.http_proxy)
        https_info = format_proxy_endpoint(config.https_proxy)

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

  defp format_proxy_endpoint(nil), do: "Not configured"

  defp format_proxy_endpoint(%{host: host, port: port, auth: auth}),
    do: "#{host}:#{port}#{auth_status(auth)}"

  defp auth_status(%ProxyCredentials{}), do: " (authenticated)"
  defp auth_status(nil), do: ""

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
      changed: LogFormat.reason(changed),
      removed: LogFormat.reason(removed)
    )

    Endpoint.config_change(changed, removed)
    :ok
  end

  # Configuration function for Oban. Queues are read and validated at runtime;
  # they can't be resolved at config time.
  @spec oban_config() :: keyword()
  defp oban_config do
    base_config = Application.get_env(:tymeslot, Oban) || [repo: Tymeslot.Repo]

    # Every environment runs the engine that carries the enqueuer's
    # correlation id into each job.
    base_config
    |> Keyword.put_new(:engine, ObanEngine)
    |> ObanQueues.build()
    |> ObanCron.extend()
  end

  # Schedule periodic jobs using TaskSupervisor for proper error handling
  @spec schedule_periodic_jobs() :: :ok
  defp schedule_periodic_jobs do
    # Mask the stored error reasons again when the masking rules have
    # changed since the last boot.
    schedule_supervised("ErrorTracker reason re-masking", fn ->
      {:ok, _job} = ErrorTrackerMaintenanceWorker.enqueue_full_remask()
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
    case Tasks.start_child(Tymeslot.TaskSupervisor, fun) do
      {:ok, _pid} ->
        Logger.info("Scheduled post-startup task", task: name)

      {:error, reason} ->
        Logger.error("Failed to schedule post-startup task",
          task: name,
          reason: LogFormat.reason(reason)
        )
    end
  end
end
