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
  # Controls whether new user registration is allowed
  registration_enabled: true,
  # Controls whether the self-host admin UI is mounted. SaaS overrides this
  # to false so the /admin scope 404s in the cloud deployment.
  enable_admin_ui: true,
  # Controls whether users must accept T&C/Privacy during registration
  enforce_legal_agreements: false,
  # Whether meeting payments (booker pays at booking time) is enabled.
  # Self-hosters opt in by setting :meeting_payments_enabled to true.
  # A downstream overlay may override this in its own config.
  meeting_payments_enabled: false,
  # Application fee charged on top of meeting payments, in basis points
  # (1 bp = 0.01%). 0 = no fee. SaaS may override per environment.
  payment_application_fee_bp: 0,
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
  about_url: nil,
  features_url: nil,
  pricing_url: nil,
  # Optional "Enterprise" marketing page, surfaced as a footer link when set.
  # nil by default so Core standalone omits it entirely; a deployment that ships
  # an enterprise page overrides it with that route.
  enterprise_url: nil,
  privacy_policy_url: nil,
  terms_and_conditions_url: nil,
  # Base URL for documentation articles. Self-hosted instances link to the public SaaS docs.
  docs_article_base_url: "https://tymeslot.app/docs",

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

  # Additional Plug.Static sources served after Core's own static files.
  # Each entry is a Plug.Static options keyword list, e.g.
  #   [at: "/", from: {:other_app, "priv/static"}, gzip: true, only: ["images"]]
  # Empty by default - external layers can serve their own static assets
  # without those files living in Core's priv/static.
  extra_static_sources: [],

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

  # Account-deletion hook - nil by default. An external layer (e.g. SaaS billing)
  # can provide a module implementing Tymeslot.Auth.Behaviours.AccountDeletionHook
  # to perform external cleanup (e.g. cancelling a subscription) that must
  # succeed before a user is deleted. See delete_user/1.
  account_deletion_hook: nil,

  # Admin alerts — disabled by default. Self-hosters can enable via the
  # ADMIN_ALERTS_ENABLED env var (set true) plus a valid ADMIN_ALERT_EMAIL.
  # A downstream overlay may override admin_alerts_enabled in its own config.
  admin_alerts_impl: Tymeslot.Infrastructure.AdminAlerts.EmailNotifier,
  admin_alerts_enabled: false,
  admin_alert_email: nil,

  # Crashes whose exception maps to a client (4xx) error are routine request
  # noise, not operator-actionable — never raise an admin alert for them.
  crash_reporter_ignored_exceptions: [
    Phoenix.Router.NoRouteError,
    Ecto.NoResultsError,
    Plug.Parsers.UnsupportedMediaTypeError,
    Plug.Parsers.RequestTooLargeError,
    Plug.BadRequestError,
    Plug.CSRFProtectionError
  ],
  # Global cap on crash alerts to survive a crash storm without flooding the
  # logging subsystem or the email queue. Tune per deployment traffic.
  crash_reporter_rate_limit_max: 20,
  crash_reporter_rate_limit_window_ms: 60_000,

  # Dashboard Extensions
  dashboard_sidebar_extensions: [],
  dashboard_action_components: %{},
  # Gettext {backend, domain} used to localise extension sidebar labels. An
  # extension owns its labels' translations in its own catalogue, so SaaS
  # overrides this to point at its backend, keeping SaaS-only strings (and SaaS
  # source paths) out of Core's publicly mirrored gettext files.
  dashboard_extension_gettext: {TymeslotWeb.Gettext, "dashboard_common"}

# Feature Announcements - Catalog modules that contribute to the
# what's-new modal shown on dashboard mount. SaaS appends its own catalog.
config :tymeslot, :announcement_catalogs, [Tymeslot.Announcements.Catalog]

# Feature Assigns - Default to allowing all features
# SaaS can override these via on_mount hooks based on subscription status.
# `:meeting_payments` defaults to false because Core treats it as a self-host
# opt-in feature; LiveViews use the assign to hide payment-related UI bits.
config :tymeslot, :feature_assigns,
  automations_allowed: true,
  custom_questions_allowed: true,
  analytics_allowed: true,
  meeting_payments: false

# Dashboard Feature Gates - Maps live_action atoms to feature flag assign keys.
# When an action is listed here, the corresponding assign must be true for the
# section to render; otherwise a placeholder is shown. SaaS can extend this map
# without modifying Core by setting :dashboard_feature_gates in its own config.
config :tymeslot, :dashboard_feature_gates, %{
  automation: :automations_allowed
}

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
  # Telegram message delivery
  telegram_messages: 10,
  # Slack message delivery
  slack_messages: 10,
  # Payment processing (used by SaaS)
  payments: 5,
  # Video room creation and management
  video_rooms: 3,
  # Calendar event sync (create, update, delete)
  calendar_events: 10,
  # Integration health checks
  calendar_integrations: 2,
  # Oban maintenance tasks (cleanup, stuck jobs)
  maintenance: 1,
  # Oban queue monitoring (separate queue to detect maintenance queue issues)
  monitoring: 1,
  # Video transcoding (responsive variant generation from uploaded videos)
  media_processing: 1

# Webhook configuration
config :tymeslot, :webhook_base_url, nil

config :tymeslot, :webhook_paths, [
  "/webhooks/stripe",
  "/webhooks/stripe/connect",
  "/auth/zoom/deauthorize"
]

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
# All supported languages with their metadata for UI rendering.
#
# A locale listed here is a promise: the completeness tests require every gettext
# domain and every /for profession page to be fully translated into it, and the
# marketing pages need a `localized_slugs` entry per profession. Add a locale only
# once its catalogues, its `priv/professions/<locale>/` files, and its URL slugs
# are all done — see priv/gettext/TRANSLATING.md.
config :tymeslot, :locales,
  supported: [
    %{code: "en", name: "English", country_code: :gbr},
    %{code: "de", name: "Deutsch", country_code: :deu},
    %{code: "fr", name: "Français", country_code: :fra},
    %{code: "it", name: "Italiano", country_code: :ita},
    %{code: "uk", name: "Українська", country_code: :ukr},
    %{code: "cs", name: "Čeština", country_code: :cze}
  ],
  default: "en"

# Pseudo-localisation ("pseudo" locale) is a dev coverage tool that rewrites
# every translated string into an accented, bracketed look-alike so un-wrapped
# literals stand out. Disabled by default; enabled in config/dev.exs only.
config :tymeslot, :pseudo_locale_enabled, false

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

# Resolve the deps directory for esbuild's NODE_PATH.
# config/ is at project_root/config/ and deps at project_root/deps/ → ../deps
esbuild_node_path = Path.expand("../deps", __DIR__)

# Configure esbuild
config :esbuild,
  version: "0.17.11",
  tymeslot: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => esbuild_node_path}
  ],
  bundles: [
    args: ~w(js/bundles/auth.js js/bundles/dashboard.js js/bundles/public.js js/bundles/core.js
        --bundle --target=es2017 --outdir=../priv/static/assets/bundles
        --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => esbuild_node_path}
  ],
  embed: [
    args: ~w(js/embed.js --bundle --target=es2017 --outfile=../priv/static/embed.js),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => esbuild_node_path}
  ],
  iframe_embed: [
    args:
      ~w(js/iframe_embed.js --bundle --target=es2017 --outfile=../priv/static/assets/iframe_embed.js),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => esbuild_node_path}
  ]

# Configure tailwind
config :tailwind,
  version: "4.3.1",
  tymeslot: [
    args: ~w(
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ],
  quill: [
    args: ~w(
      --input=css/scheduling/themes/quill/theme.css
      --output=../priv/static/assets/scheduling-theme-quill.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ],
  rhythm: [
    args: ~w(
      --input=css/scheduling/themes/rhythm/theme.css
      --output=../priv/static/assets/scheduling-theme-rhythm.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Precompressed siblings written by `mix phx.digest`, replacing the stock
# [Phoenix.Digester.Gzip]. Order is irrelevant here; what a client is offered
# is decided by the endpoint's :encodings list. See the module for why both
# variants are worth writing.
config :phoenix, :static_compressors, [
  Tymeslot.Infrastructure.StaticCompressors.Zstd,
  Tymeslot.Infrastructure.StaticCompressors.Gzip
]

# Configure timezone database
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Pin the IANA time zone database to a release we vendor ourselves, rather than
# whichever one the `tz` package happens to bundle. `tz` 0.28.2 ships 2026b,
# which predates two transitions that fall inside the default 90-day booking
# window: Morocco moving to permanent UTC on 2026-09-20, and Alberta moving to
# permanent -06 on 2026-11-01. Both would put slots an hour out.
#
# The files live in Core's priv so builds stay hermetic (no fetch from
# data.iana.org at image build). `__DIR__` keeps the path anchored to Core even
# when the SaaS overlay imports this file. Refresh with:
#
#     mix tz.download <version> && mix deps.compile tz --force
#
# then bump :iana_version to match. Tz.WatchPeriodically logs when a newer
# release appears upstream; see Tymeslot.Application.
config :tz, :data_dir, Path.expand("../priv/tz", __DIR__)
config :tz, :iana_version, "2026c"

# Watch data.iana.org for time zone releases newer than the pinned one. Logs
# only; enabled in prod.exs so dev and test make no outbound calls.
config :tymeslot, :tz_watch_enabled, false

# Authentication configuration
config :tymeslot, :auth,
  success_redirect_path: "/dashboard",
  login_path: "/auth/login"

# Input validation configuration. Core has no reader of its own; the key is
# consumed by projects depending on this one as a path dependency, to cap
# free-text form input. Those readers carry their own compile-time default
# matching this value, so the cap holds even without this key — but keep it
# here, or a "no reader in Core" sweep will delete a value something reads.
config :tymeslot, :field_validation, universal_max_length: 10_000

# Social Authentication Configuration moved to runtime.exs (needs runtime env vars)

config :tymeslot, :transcoder, Tymeslot.Media.Transcoder

# Provider enable/disable switches
config :tymeslot, :video_providers, %{
  mirotalk: [enabled: true],
  google_meet: [enabled: true],
  teams: [enabled: true],
  custom: [enabled: true]
}

# Whether this deployment's Zoom Marketplace app is configured for
# `meeting:update:meeting`. Off by default: requesting a scope the app lacks is
# silently dropped by Zoom, and would make Tymeslot ask users to reconnect for a
# scope no reconnect can produce. See `ZoomProvider.Scopes`.
config :tymeslot, :zoom_update_scope_enabled, false

config :tymeslot, :calendar_providers, %{
  caldav: [enabled: true],
  radicale: [enabled: true],
  nextcloud: [enabled: true],
  zimbra: [enabled: true],
  mailbox_org: [enabled: true],
  apple: [enabled: true],
  baikal: [enabled: true],
  google: [enabled: true],
  outlook: [enabled: true],
  exchange: [enabled: true],
  # Internal providers — never user-connectable. Disabled explicitly because
  # the runtime toggle defaults to enabled for any provider in @providers.
  demo: [enabled: false],
  debug: [enabled: false]
}

# Integration locking configuration
config :tymeslot, :integration_locks,
  default_timeout: 90_000,
  google: 60_000,
  outlook: 60_000,
  teams: 120_000

# Pin the Stripe API version instead of inheriting stripity_stripe's built-in
# default, which travels with the library: upgrading the dependency would move
# the wire contract without any change here. This matches the version the
# locked stripity_stripe generates its structs from; the consumers of the
# fields that moved in 2025-03-31.basil (billing periods on subscription
# items, invoice subscription reference under parent, charges without
# invoice links) accept both the old and new shapes. Webhook payload shape
# follows the endpoint version configured in the Stripe dashboard, not this
# pin — keep the two in step.
config :stripity_stripe, api_version: "2025-11-17.clover"

# Default country code (ISO 3166-1 alpha-2) for Stripe Connect onboarding when
# the host's profile carries no explicit country. Configurable via the
# MEETING_PAYMENTS_DEFAULT_COUNTRY env var (read in runtime.exs).
config :tymeslot, :meeting_payments_default_country, "ch"

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

# Refund handling configuration. The revocation threshold is read by Core's
# refund webhook handler (Tymeslot.Payments.Webhooks.RefundHandler), so it stays
# in Core even though only paid deployments exercise it.
config :tymeslot,
  # Percentage threshold for revoking access after refund (0-100)
  # Access is revoked only if total refunds >= this percentage of original charge
  refund_revocation_threshold_percent: 90.0

# Data retention windows for the cross-domain pruning worker
# (Tymeslot.Workers.DataRetentionWorker), read via Application.compile_env. Because
# compile_env requires identical compile-time and runtime values, this key must
# have a single owner — keep only retention here. An external overlay that adds a
# dunning schedule must use its own separate config key, never extend :payments.
config :tymeslot, :payments,
  retention: [
    outgoing_webhook_days: 60,
    stripe_event_days: 90,
    analytics_event_days: 90,
    payload_days: 30
  ]

# Slack notifications — credentials supplied via env at runtime
config :tymeslot,
  slack_notifications_allowed: false,
  slack_oauth_available: false,
  slack_client_id: nil,
  slack_client_secret: nil

# Booking analytics — page-view tracking, cookie-less visitor fingerprinting,
# UTM/referrer capture on bookings, and the attribution dashboard. Off by
# default so self-hosters do not collect visitor analytics unless they opt in;
# the managed SaaS overrides this to `true`.
config :tymeslot, :booking_analytics_enabled, false

# The date booking analytics began collecting on this installation. When set,
# the analytics dashboard explains that windows reaching before it are empty
# because no data existed yet — so a freshly launched feature reads as new
# rather than broken. `nil` (the default) shows no such notice; the managed
# SaaS sets its go-live date.
config :tymeslot, :booking_analytics_launch_date, nil

# Analytics — secret used to derive the daily-rotated visitor fingerprint salt.
# Required in production; dev/test override with fixed values for repeatability.
config :tymeslot, :analytics_salt_secret, nil

# Migration safety analysis (excellent_migrations, run as its own gate step
# rather than a Credo check: migrations are deliberately outside .credo.exs's
# included paths, so that they do not attract ModuleDoc, Specs and the rest).
# The 178 migrations written before it was adopted are grandfathered: they have
# already shipped and run against real databases, so re-litigating them would
# be noise rather than safety. Anything strictly after this timestamp is checked.
config :excellent_migrations, start_after: "20260716094322"

# Import environment specific config
import_config "#{config_env()}.exs"
