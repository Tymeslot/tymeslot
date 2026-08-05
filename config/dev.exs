import Config

# Configure environment
config :tymeslot, environment: :dev

# Enable the pseudo-localisation locale in dev. Visit any page with
# `?locale=pseudo` to render every translated string as an accented, bracketed
# look-alike — un-wrapped literals show up plain. Never enabled outside dev.
config :tymeslot, :pseudo_locale_enabled, true

# Configure upload directory for development
config :tymeslot, :upload_directory, Path.expand("../uploads", __DIR__)

# Generated URLs (email links, OAuth redirect URIs) come from the endpoint's
# :url config, so a dev server reached through a reverse proxy must know the
# domain the browser actually used. These read the same variables runtime.exs
# reads in production; unset, they collapse to the previous http://localhost:PORT
# behaviour exactly.
port = String.to_integer(System.get_env("PORT") || "4000")
host = System.get_env("PHX_HOST") || "localhost"
url_scheme = System.get_env("URL_SCHEME") || "http"

# As in runtime.exs, a TLS scheme means the proxy terminates on the standard
# port, so generated links carry no port suffix. Direct access instead needs the
# listen port to appear in the URL, which is the default path here.
url_port = if url_scheme == "https", do: 443, else: port

config :tymeslot, TymeslotWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: port],
  url: [host: host, port: url_port, scheme: url_scheme],
  # The proxied origin has to be allowed too, or the LiveView socket is rejected
  # under the very domain PHX_HOST just enabled. Deduplicated so the default case
  # produces the same two entries it always did.
  check_origin:
    Enum.uniq([
      "#{url_scheme}://#{host}:#{url_port}",
      "http://localhost:#{port}",
      "http://127.0.0.1:#{port}"
    ]),
  code_reloader: true,
  debug_errors: true,
  secret_key_base:
    System.get_env("SECRET_KEY_BASE") ||
      "1H+dLz1eQCL1mH8vjh5SJUR2Z5QULWP9bH3j8+BwnBSfS9J74akhHrGFpjezqJqd",
  live_view: [signing_salt: "dev_liveview_signing_salt"],
  session_signing_salt: "dev_session_signing_salt",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:tymeslot, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:tymeslot, ~w(--watch)]},
    tailwind_quill: {Tailwind, :install_and_run, [:quill, ~w(--watch)]},
    tailwind_rhythm: {Tailwind, :install_and_run, [:rhythm, ~w(--watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/tymeslot_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

# Data-at-rest encryption key, decoupled from SECRET_KEY_BASE. Dev defaults to the
# legacy SECRET_KEY_BASE-derived key (like a fresh self-host that has not set the
# variable); set DATA_ENCRYPTION_KEY (e.g. in env.sh) to exercise the decoupled
# key. There is deliberately no hardcoded default: a fixed dev key would be
# silently overridden the moment you set your own, stranding credentials already
# written under it. Production supplies the key via runtime.exs.
config :tymeslot, Tymeslot.Security.Encryption,
  data_encryption_key: System.get_env("DATA_ENCRYPTION_KEY")

# Enable dev routes for dashboard and mailbox
config :tymeslot, dev_routes: true

# Show metadata fields in development logs for observability
config :logger, :console,
  format: "[$level] $message $metadata\n",
  metadata: [:request_id, :user_id, :correlation_id, :event, :domain, :reason]

# Set a higher stacktrace during development
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  enable_expensive_runtime_checks: true

# Configure the database
config :tymeslot, Tymeslot.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "tymeslot_dev#{System.get_env("DB_SUFFIX")}",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 80

# Configure Oban for development
# Queue definitions in config.exs are loaded at runtime by application.ex
# This allows SaaS to extend Core queues via :oban_additional_queues config
config :tymeslot, Oban,
  repo: Tymeslot.Repo,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 604_800},
    {Oban.Plugins.Cron,
     crontab: [
       # Run every 30 minutes
       {"*/30 * * * *", Tymeslot.Workers.ObanMaintenanceWorker},
       # Run every hour at the top of the hour
       {"0 * * * *", Tymeslot.Workers.ObanQueueMonitorWorker},
       # Run daily at 02:45 UTC
       {"45 2 * * *", Tymeslot.Workers.VideoRoomRecoveryScanWorker},
       # Run daily at 03:45 UTC to clean up cancelled meetings' orphaned rooms
       {"45 3 * * *", Tymeslot.Workers.OrphanedVideoRoomScanWorker},
       # Run daily at 02:00 UTC to renew expiring webhook channels
       {"0 2 * * *", Tymeslot.Workers.RenewWebhookChannelsWorker},
       # Run daily at 04:00 UTC
       {"0 4 * * *", Tymeslot.Workers.DataRetentionWorker, args: %{retention_days: 60}},
       # Run every 6 hours to detect silent/dead webhook channels
       {"0 */6 * * *", Tymeslot.Workers.DeadChannelAlertWorker},
       # Run every 15 min; CalDAV tier-aware filtering decides which integrations sync
       {"*/15 * * * *", Tymeslot.Workers.FallbackSyncSweepWorker},
       # Run daily at 03:30 UTC to prune old/inactive calendar event cache
       {"30 3 * * *", Tymeslot.Workers.CalendarCachePruneWorker},
       # Run daily at 05:00 UTC to auto-pause integrations stuck unhealthy past the configured cutoff
       {"0 5 * * *", Tymeslot.Workers.IntegrationAutoPauseWorker},
       # Run every 15 min to reconcile awaiting_payment meetings whose webhook never arrived
       {"*/15 * * * *", Tymeslot.MeetingPayments.Workers.ReconcileAwaitingPayments},
       # Run daily at 04:30 UTC to cross-check booking analytics against bookings
       {"30 4 * * *", Tymeslot.Workers.AnalyticsReconciliationWorker}
     ]}
  ]

# Enable swoosh api client
config :swoosh, :api_client, Swoosh.ApiClient.Hackney

# Webhook verification enabled by default
config :tymeslot, :skip_webhook_verification, false

# Analytics fingerprint salt secret — fixed dev value. Production must override
# via the ANALYTICS_SALT_SECRET environment variable (see runtime.exs).
config :tymeslot, :analytics_salt_secret, "dev_analytics_salt_secret_change_in_prod"

# Enable booking analytics in development so the feature is exercisable locally.
config :tymeslot, :booking_analytics_enabled, true

# Opt-in dev calendar stub: bypasses real CalDAV/Google/Outlook and computes
# availability against a controllable, in-memory busy set — handy for booking-UI
# and scheduling-theme work. Adjust it live from IEx (block dates, add busy
# periods) via Tymeslot.Dev.Calendar. Left unset, dev uses the real calendar so
# genuine sync can be exercised.
#
#   * DEV_CALENDAR=1       → starts with a realistic recurring weekly pattern.
#   * DEV_EMPTY_CALENDAR=1 → starts empty (every slot free), preserving the
#     previous behaviour.
cond do
  System.get_env("DEV_CALENDAR") in ~w(1 true) ->
    config :tymeslot, :calendar_module, Tymeslot.Dev.Calendar
    config :tymeslot, :dev_calendar_enabled, true
    config :tymeslot, :dev_calendar_default_pattern, :default

  System.get_env("DEV_EMPTY_CALENDAR") in ~w(1 true) ->
    config :tymeslot, :calendar_module, Tymeslot.Dev.Calendar
    config :tymeslot, :dev_calendar_enabled, true
    config :tymeslot, :dev_calendar_default_pattern, :empty

  true ->
    :ok
end

# Compile-time gate for the /dev/* routes in TymeslotWeb.Router. A config flag
# rather than Mix.env(): when Core is consumed as a path dependency, Mix.env()
# inside the dep evaluates to the dep's own environment, not the parent's.
config :tymeslot, dev_routes: true
