import Config

# Configure environment
config :tymeslot, environment: :dev

# Configure upload directory for development
config :tymeslot, :upload_directory, Path.expand("../uploads", __DIR__)

config :tymeslot, TymeslotWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4000")],
  url: [
    host: "localhost",
    port: String.to_integer(System.get_env("PORT") || "4000"),
    scheme: "http"
  ],
  check_origin: [
    "http://localhost:#{System.get_env("PORT") || "4000"}",
    "http://127.0.0.1:#{System.get_env("PORT") || "4000"}"
  ],
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

# Enable dev routes for dashboard and mailbox
config :tymeslot, dev_routes: true

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
  database: "tymeslot_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 60

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
       # Run daily at 04:00 UTC
       {"0 4 * * *", Tymeslot.Workers.WebhookCleanupWorker, args: %{retention_days: 60}}
     ]}
  ]

# Enable swoosh api client
config :swoosh, :api_client, Swoosh.ApiClient.Hackney

# Webhook verification enabled by default
config :tymeslot, :skip_webhook_verification, false
