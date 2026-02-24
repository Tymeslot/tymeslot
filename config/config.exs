import Config

# =============================================================================
# TYMESLOT CORE: BASE CONFIGURATION
# =============================================================================
# Core provides the infrastructure and default behaviors for a standalone
# scheduling engine. All advanced features are disabled by default.
config :tymeslot,
  ecto_repos: [Tymeslot.Repo],
  generators: [timestamp_type: :utc_datetime],

  # --- Feature Flags ---
  # Controls whether users must accept T&C/Privacy during registration
  enforce_legal_agreements: false,
  # Whether to show marketing-related links (Docs, etc) in navigation
  show_marketing_links: false,
  # Whether the logo links to a marketing site or the login page
  logo_links_to_marketing: false,
  legal_terms_url: nil,
  legal_privacy_url: nil,

  # Navigation: Where the logo/home link points to
  site_home_path: "/dashboard",
  repo: Tymeslot.Repo,
  contact_url: nil,
  privacy_policy_url: nil,
  terms_and_conditions_url: nil,

  # --- Integration & Routing ---
  # The primary router to use for the application
  router: TymeslotWeb.Router,

  # Default email settings for standalone use
  email_adapter_default: "smtp",
  trial_ending_reminder_template: nil,
  refund_processed_template: nil,
  dispute_alert_template: nil,

  # Theme protection plugs - empty by default (external layers can add restrictions)
  extra_theme_protection_plugs: [],

  # Theme extensions - empty by default (external layers can add overlays/branding)
  theme_extensions: [],

  # Additional CSS files for scheduling pages - empty by default (external layers can inject CSS)
  scheduling_additional_css: [],

  # Analytics configuration - nil by default (no analytics)
  # Can be configured as a list of provider configs
  analytics_providers: nil,

  # Whether to show "Powered by Tymeslot" branding on scheduling pages.
  # This should remain false in the standalone open-source version.
  show_branding: false,

  # Demo provider - no-op by default (can be provided by external layers)
  demo_provider: Tymeslot.Demo.NoOp,

  # Subscription manager - nil by default (can be provided by external layers)
  subscription_manager: nil,

  # Admin alerts module - nil by default (can be provided by external layers)
  admin_alerts_impl: Tymeslot.Infrastructure.AdminAlerts.Default,

  # Dashboard Extensions
  dashboard_sidebar_extensions: [],
  dashboard_action_components: %{}

# Feature Assigns - Default to allowing all features
# SaaS can override these via on_mount hooks based on subscription status
config :tymeslot, :feature_assigns, automations_allowed: true

# Feature Access Checker - Default to allowing all features
# SaaS can provide a custom implementation that checks subscription status
config :tymeslot, :feature_access_checker, Tymeslot.Features.DefaultAccessChecker

# Oban queues shared across environments
# Queue definitions are specified here but loaded at runtime by application.ex
# This allows SaaS to extend Core queues via :oban_additional_queues config
# Each queue has a concurrency limit that determines how many jobs can run simultaneously.
config :tymeslot, :oban_queues,
  default: 10,
  # Email sending (confirmations, reminders, auth emails)
  # Concurrency increased from 5 to 10 to handle higher email volume
  # Note: Monitor SMTP provider rate limits. Most providers (Gmail, Postmark, etc.)
  # handle this concurrency well, but adjust if you encounter rate limiting.
  emails: 10,
  # Webhook delivery to external services
  webhooks: 5,
  # Payment processing (used by SaaS)
  payments: 5,
  # Video room creation and management
  video_rooms: 3,
  # Calendar event sync (create, update, delete)
  calendar_events: 5,
  # Integration health checks
  calendar_integrations: 2,
  # Oban maintenance tasks (cleanup, stuck jobs)
  maintenance: 1,
  # Oban queue monitoring (separate queue to detect maintenance queue issues)
  monitoring: 1

# Webhook configuration
config :tymeslot, :webhook_paths, ["/webhooks/stripe"]

# Webhook idempotency cache TTLs
config :tymeslot, :webhook_idempotency,
  # How long to reserve an event while processing (prevents duplicate processing)
  processing_ttl_ms: :timer.minutes(10),
  # How long to remember a processed event (prevents replay attacks)
  processed_ttl_ms: :timer.hours(24)

# =============================================================================
# INTERNATIONALIZATION (I18N) CONFIGURATION
# =============================================================================

# Configure Gettext default locale
config :tymeslot, TymeslotWeb.Gettext, default_locale: "en"

# Locale configuration (single source of truth)
# All supported languages with their metadata for UI rendering
config :tymeslot, :locales,
  supported: [
    %{code: "en", name: "English", country_code: :gbr},
    %{code: "de", name: "Deutsch", country_code: :deu},
    %{code: "uk", name: "Українська", country_code: :ukr},
    %{code: "fr", name: "Français", country_code: :fra}
  ],
  default: "en"

# =============================================================================
# SHARED INFRASTRUCTURE CONFIGURATION
# =============================================================================

# Configures the endpoint
config :tymeslot, TymeslotWeb.Endpoint,
  url: [host: "localhost", scheme: "http"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TymeslotWeb.ErrorHTML, json: TymeslotWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Tymeslot.PubSub

# Configures the mailer
config :tymeslot, Tymeslot.Mailer, adapter: Swoosh.Adapters.Local

# Configure Swoosh API client
config :swoosh, :api_client, Swoosh.ApiClient.Hackney

# Configure esbuild
config :esbuild,
  version: "0.17.11",
  tymeslot: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ],
  bundles: [
    args: ~w(js/bundles/auth.js js/bundles/dashboard.js js/bundles/public.js js/bundles/core.js
        --bundle --target=es2017 --outdir=../priv/static/assets/bundles
        --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind
config :tailwind,
  version: "3.4.3",
  tymeslot: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ],
  quill: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/scheduling/themes/quill/theme.css
      --output=../priv/static/assets/scheduling-theme-quill.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ],
  rhythm: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/scheduling/themes/rhythm/theme.css
      --output=../priv/static/assets/scheduling-theme-rhythm.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure timezone database
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Authentication configuration
config :tymeslot, :auth, success_redirect_path: "/dashboard"

# Input validation configuration
config :tymeslot, :field_validation,
  email_max_length: 254,
  name_min_length: 2,
  name_max_length: 100,
  universal_max_length: 10_000,
  password_min_length: 8,
  password_max_length: 80,
  full_name_max_length: 100

# Social Authentication Configuration moved to runtime.exs (needs runtime env vars)

# Provider enable/disable switches
config :tymeslot, :video_providers, %{
  mirotalk: [enabled: true],
  google_meet: [enabled: true],
  teams: [enabled: true],
  custom: [enabled: true]
}

config :tymeslot, :calendar_providers, %{
  caldav: [enabled: true],
  radicale: [enabled: true],
  nextcloud: [enabled: true],
  zimbra: [enabled: true],
  google: [enabled: true],
  outlook: [enabled: true]
}

# Integration locking configuration
config :tymeslot, :integration_locks,
  default_timeout: 90_000,
  google: 60_000,
  outlook: 60_000,
  teams: 120_000

# Payment rate limiting configuration
config :tymeslot, :payment_rate_limits,
  # Maximum number of payment initiation attempts per user
  max_attempts: 5,
  # Time window in milliseconds (10 minutes)
  window_ms: 600_000

# Payment amount bounds in cents to prevent extreme charges
config :tymeslot, :payment_amount_limits,
  min_cents: 50,
  max_cents: 1_000_000_00

# Payment retry configuration
config :tymeslot, :payment_retry,
  # Maximum number of retry attempts for transient failures
  max_attempts: 3,
  # Base delay between retries in milliseconds
  base_delay_ms: 1000,
  # Multiplier for exponential backoff (1 = linear backoff)
  backoff_multiplier: 1

# Subscription trial configuration
config :tymeslot,
  # Default trial period for new subscriptions (in days)
  trial_period_days: 7

# Refund handling configuration
config :tymeslot,
  # Percentage threshold for revoking access after refund (0-100)
  # Access is revoked only if total refunds >= this percentage of original charge
  refund_revocation_threshold_percent: 90.0

# Abandoned transaction configuration
config :tymeslot,
  # Time threshold in seconds before a pending transaction is considered abandoned
  # Used for sending reminder emails to users who didn't complete checkout
  abandoned_transaction_threshold_seconds: 600

# Dunning and Retention configuration
config :tymeslot, :payments,
  dunning: [
    days_until_cancel: 14,
    reminder_days: [0, 3, 7, 14]
  ],
  retention: [
    outgoing_webhook_days: 60,
    stripe_event_days: 90
  ]

# Subscription reconciliation configuration
config :tymeslot, :reconciliation,
  # Automatically fix safe discrepancies (e.g., status mismatches, missing locally)
  auto_fix_safe_discrepancies: true,
  # Send alerts to admins when discrepancies are found
  alert_admins: true,
  # Number of days to look back when fetching subscriptions for reconciliation
  days_back: 7

# Import environment specific config
import_config "#{config_env()}.exs"
