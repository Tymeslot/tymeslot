import Config
require Logger

# Load `.env` before any `System.get_env/1` so it populates unset vars. Shell
# vars always win. On Cloudron `/app` is read-only and reset on every upgrade,
# so `.env` lives on the persistent `/app/data` volume.
if config_env() != :test do
  dotenv_path =
    if System.get_env("DEPLOYMENT_TYPE") == "cloudron" do
      "/app/data/.env"
    else
      Path.join(System.get_env("RELEASE_ROOT") || Path.expand("..", __DIR__), ".env")
    end

  Tymeslot.Infrastructure.DotenvLoader.load([dotenv_path])
end

# Helper to parse IP addresses using Erlang's built-in parser
# Supports both IPv4 and IPv6 addresses in all standard notations
parse_ip = fn ip_string ->
  case :inet.parse_address(String.to_charlist(ip_string)) do
    {:ok, ip_tuple} ->
      ip_tuple

    {:error, :einval} ->
      raise """
      Invalid LISTEN_IP: #{inspect(ip_string)}

      Must be a valid IPv4 or IPv6 address. Examples:
        IPv4: 0.0.0.0 (all interfaces), 127.0.0.1 (localhost only)
        IPv6: :: (all interfaces), ::1 (localhost only)

      Common use cases:
        - All interfaces (default): :: or 0.0.0.0
        - Localhost only (service mesh): ::1 or 127.0.0.1
        - Specific interface: fe80::1 or 192.168.1.100
      """
  end
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# =============================================================================
# HTTP PROXY CONFIGURATION
# =============================================================================
# Parse HTTP/HTTPS proxy configuration from standard environment variables.
# Supports: HTTP_PROXY, HTTPS_PROXY, NO_PROXY (case-insensitive)
# This configuration applies to all outbound HTTP requests (CalDAV, Google API, etc.)

# Helper to parse a proxy URL into structured config
parse_proxy_url = fn proxy_url ->
  if proxy_url && proxy_url != "" do
    uri = URI.parse(proxy_url)

    # Parse authentication from URL userinfo
    proxy_auth =
      case uri.userinfo do
        nil ->
          nil

        userinfo ->
          case String.split(userinfo, ":", parts: 2) do
            [user, pass] -> {URI.decode(user), URI.decode(pass)}
            [user] -> {URI.decode(user), ""}
          end
      end

    %{
      host:
        uri.host ||
          raise("Proxy URL must include a valid host (check HTTP_PROXY/HTTPS_PROXY format)"),
      port: uri.port || 8080,
      auth: proxy_auth,
      scheme: uri.scheme || "http"
    }
  else
    nil
  end
end

# Read proxy environment variables (case-insensitive, uppercase takes precedence)
http_proxy_url = System.get_env("HTTP_PROXY") || System.get_env("http_proxy")
https_proxy_url = System.get_env("HTTPS_PROXY") || System.get_env("https_proxy")
no_proxy_raw = System.get_env("NO_PROXY") || System.get_env("no_proxy") || ""

# Parse NO_PROXY into list of patterns
no_proxy_list =
  no_proxy_raw
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))

# Build proxy configuration
proxy_config =
  if http_proxy_url || https_proxy_url do
    %{
      http_proxy: parse_proxy_url.(http_proxy_url),
      https_proxy: parse_proxy_url.(https_proxy_url),
      no_proxy: no_proxy_list
    }
  else
    nil
  end

# Store proxy config for use by Req
config :tymeslot, :http_proxy, proxy_config

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/tymeslot start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :tymeslot, TymeslotWeb.Endpoint, server: true
end

if System.get_env("E2E") == "true" do
  config :tymeslot, TymeslotWeb.Endpoint, server: true
end

if config_env() == :prod do
  # Set environment for runtime detection
  config :tymeslot, :environment, :prod

  # Do not print debug messages in production
  config :logger, level: :info

  # Disable tzdata auto-updates: the release filesystem is read-only in containers.
  # Timezone data is bundled at build time; redeploy to pick up tz updates.
  config :tzdata, :autoupdate, :disabled

  # Point tzdata at a writable directory so it doesn't crash trying to write
  # poll timestamps to the read-only release filesystem. The start script
  # seeds this directory with the bundled release_ets data on first boot.
  config :tzdata, :data_dir, "/app/data/tzdata"

  # Structured JSON logging for production containers.
  #
  # `:all_except` captures every keyword metadata field passed inline or set on
  # the process, minus the noisy OTP internals listed below. `:domain` is kept
  # because StructuredLogger tags log lines with `domain: :authentication`,
  # `:database`, etc. — that key is what enables domain-faceted log queries.
  config :logger, :default_handler,
    formatter:
      LoggerJSON.Formatters.Basic.new(metadata: {:all_except, [:conn, :socket, :mfa, :pid, :gl]})

  # Database configuration based on deployment type (define early as it's used for URL scheme)
  # Defaults to "docker" if DEPLOYMENT_TYPE is not set or unknown
  deployment_type =
    case System.get_env("DEPLOYMENT_TYPE") do
      "cloudron" -> "cloudron"
      "main" -> "cloudron"
      _ -> "docker"
    end

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # Data-at-rest encryption key, decoupled from SECRET_KEY_BASE so the cookie
  # signing secret can be rotated without touching stored credentials. Absent is
  # allowed (the keyring falls back to the legacy SECRET_KEY_BASE-derived key and
  # keeps writing the old format), so existing deployments upgrade with no change;
  # a malformed value raises in the encryption module. Once set, run the
  # re-encryption sweep (see README, "Data-at-rest encryption") to migrate
  # existing values, then the two secrets are fully independent.
  data_encryption_key = System.get_env("DATA_ENCRYPTION_KEY")

  if is_nil(data_encryption_key) do
    IO.warn(
      "DATA_ENCRYPTION_KEY is not set; data-at-rest credentials are still encrypted " <>
        "with a key derived from SECRET_KEY_BASE. Rotating SECRET_KEY_BASE would make " <>
        "them undecryptable. Set DATA_ENCRYPTION_KEY (e.g. `openssl rand -base64 48`) " <>
        "and run the re-encryption sweep (see README, \"Data-at-rest encryption\") to " <>
        "decouple them.",
      []
    )
  end

  config :tymeslot, Tymeslot.Security.Encryption, data_encryption_key: data_encryption_key

  host =
    System.get_env("PHX_HOST") ||
      System.get_env("CLOUDRON_APP_DOMAIN") ||
      raise("environment variable PHX_HOST is missing")

  port = String.to_integer(System.get_env("PORT") || "4000")

  # Allowed origins for LiveView WebSocket (align with CSP 'connect-src' and site origin)
  # Both Cloudron and Docker build an allow-list from the host
  check_origin_config =
    case deployment_type do
      "cloudron" ->
        ["https://#{host}", "http://#{host}"]

      "docker" ->
        case System.get_env("WS_ALLOWED_ORIGINS") do
          nil ->
            [
              "https://#{host}",
              "http://#{host}",
              "http://localhost:4000",
              "https://localhost:4000"
            ]

          list ->
            list
            |> String.split(",")
            |> Enum.map(&String.trim/1)
        end
    end

  config :tymeslot, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # URL scheme: Cloudron always uses https, Docker defaults to https but can override
  # Production deployments should use https via reverse proxy (nginx, Caddy, Traefik, etc.)
  url_scheme =
    case deployment_type do
      "cloudron" -> "https"
      "docker" -> System.get_env("URL_SCHEME", "https")
    end

  # URL port for generation (what appears in generated URLs)
  # Production: Always use standard ports (80/443) - assumes reverse proxy on standard ports
  # Dev: Uses PORT variable directly (e.g., 4000) via dev.exs
  # This ensures production URLs never include port suffix (https://example.com not https://example.com:443)
  url_port =
    case deployment_type do
      "cloudron" -> 443
      "docker" -> if url_scheme == "https", do: 443, else: 80
    end

  # Listen IP configuration
  # Default to :: (IPv6 any address, which also accepts IPv4 on dual-stack systems)
  # Override with LISTEN_IP environment variable for specific use cases:
  #   - IPv4-only environments: LISTEN_IP=0.0.0.0
  #   - Service mesh (localhost only): LISTEN_IP=127.0.0.1 or LISTEN_IP=::1
  #   - Specific interface: LISTEN_IP=192.168.1.100 or LISTEN_IP=fe80::1
  listen_ip = System.get_env("LISTEN_IP") || "::"

  config :tymeslot, TymeslotWeb.Endpoint,
    url: [host: host, port: url_port, scheme: url_scheme],
    http: [
      ip: parse_ip.(listen_ip),
      port: port
    ],
    secret_key_base: secret_key_base,
    check_origin: check_origin_config

  # Database configuration. The mapping from environment to Repo options lives
  # in a module so it can be unit-tested; this file is never evaluated by
  # `mix test`.
  config :tymeslot,
         Tymeslot.Repo,
         Tymeslot.Infrastructure.DatabaseConfig.build(deployment_type, System.get_env())

  # Remote IP handling: trust private/loopback proxies and read proxy headers
  # Cloudron uses x-forwarded-for header from its reverse proxy
  config :remote_ip, RemoteIp,
    headers: ~w[x-forwarded-for x-real-ip],
    proxies: ~w[
      127.0.0.0/8
      10.0.0.0/8
      172.16.0.0/12
      192.168.0.0/16
      ::1/128
      fc00::/7
      fd00::/8
    ]

  # Configure Oban for production
  # Queue definitions in config.exs are loaded at runtime by application.ex
  # This allows SaaS to extend Core queues via :oban_additional_queues config
  config :tymeslot, Oban,
    repo: Tymeslot.Repo,
    # Allow in-flight jobs 15 seconds to finish on shutdown before being rescheduled
    shutdown_grace_period: :timer.seconds(15),
    pruner: [max_age: {7, :days}],
    cron: [
      crontab: [
        # Run every 30 minutes for Oban maintenance
        {"*/30 * * * *", Tymeslot.Workers.ObanMaintenanceWorker},
        # Run every hour for queue health monitoring
        {"0 * * * *", Tymeslot.Workers.ObanQueueMonitorWorker},
        # Run daily at 02:45 UTC for video room recovery scan
        {"45 2 * * *", Tymeslot.Workers.VideoRoomRecoveryScanWorker},
        # Run daily at 03:45 UTC to re-attempt provider deletion for cancelled
        # meetings whose video room was never cleaned up
        {"45 3 * * *", Tymeslot.Workers.OrphanedVideoRoomScanWorker},
        # Run daily at 03:15 UTC
        {"15 3 * * *", Tymeslot.Workers.ExpiredSessionCleanupWorker},
        # Run daily at 02:00 UTC to renew expiring webhook channels
        {"0 2 * * *", Tymeslot.Workers.RenewWebhookChannelsWorker},
        # Run every 15 min; CalDAV tier-aware filtering decides which integrations sync
        {"*/15 * * * *", Tymeslot.Workers.FallbackSyncSweepWorker},
        # Run daily at 04:00 UTC for cross-domain data retention pruning
        {"0 4 * * *", Tymeslot.Workers.DataRetentionWorker, args: %{retention_days: 60}},
        # Run every 6 hours to detect silent/dead webhook channels
        {"0 */6 * * *", Tymeslot.Workers.DeadChannelAlertWorker},
        # Run daily at 03:30 UTC to prune old/inactive calendar event cache
        {"30 3 * * *", Tymeslot.Workers.CalendarCachePruneWorker},
        # Run daily at 05:00 UTC to auto-pause integrations stuck unhealthy past the configured cutoff
        {"0 5 * * *", Tymeslot.Workers.IntegrationAutoPauseWorker},
        # Run every 15 min to reconcile awaiting_payment meetings whose webhook never arrived
        {"*/15 * * * *", Tymeslot.MeetingPayments.Workers.ReconcileAwaitingPayments},
        # Run daily at 04:30 UTC to cross-check booking analytics against bookings
        {"30 4 * * *", Tymeslot.Workers.AnalyticsReconciliationWorker}
      ]
    ]

  # Configure mailer based on EMAIL_ADAPTER setting. `Tymeslot.Mailer.Providers`
  # owns the list of supported values and the variables each one reads; an
  # unrecognised value raises rather than silently discarding every email.
  # Default to smtp for self-hosted deployments.
  # On Cloudron: auto-detect sendmail addon when EMAIL_ADAPTER is not explicitly set.
  # A set-but-blank EMAIL_ADAPTER= is treated the same as unset, so it falls
  # through to the default/auto-detection below instead of raising as an
  # unrecognised provider name.
  email_adapter_explicit =
    "EMAIL_ADAPTER" |> System.get_env() |> Tymeslot.Mailer.Providers.blank_to_nil()

  mailer_config =
    cond do
      # Explicit adapter always wins — user knows what they want
      email_adapter_explicit != nil ->
        if Tymeslot.Mailer.Providers.dev_only?(email_adapter_explicit) do
          raise """
          EMAIL_ADAPTER=#{String.trim(email_adapter_explicit)} is a development-only adapter.

          Swoosh's in-memory mailbox is disabled in production, so it cannot
          deliver anything. Configure a real provider, or set EMAIL_ADAPTER=test
          if you deliberately want every email discarded.
          """
        end

        Tymeslot.Mailer.Providers.build!(email_adapter_explicit)

      # Cloudron sendmail addon auto-detection (no explicit EMAIL_ADAPTER set)
      deployment_type == "cloudron" and System.get_env("CLOUDRON_MAIL_SMTP_SERVER") != nil ->
        Tymeslot.Mailer.CloudronConfig.build(
          server: System.get_env("CLOUDRON_MAIL_SMTP_SERVER"),
          port: System.get_env("CLOUDRON_MAIL_SMTP_PORT"),
          username: System.get_env("CLOUDRON_MAIL_SMTP_USERNAME"),
          password: System.get_env("CLOUDRON_MAIL_SMTP_PASSWORD")
        )

      # Default: standard SMTP from SMTP_* env vars
      true ->
        Tymeslot.Mailer.Providers.build!("smtp")
    end

  config :tymeslot, Tymeslot.Mailer, mailer_config

  # Analytics fingerprint salt secret — keys the cookie-less daily visitor hash
  # and must never leave the server. It is required ONLY when booking analytics
  # is enabled (`config :tymeslot, :booking_analytics_enabled, true`); self-hosters
  # who never opt into analytics are not forced to set it.
  #
  # When the feature IS enabled we fail fast at boot rather than silently fall
  # back to a weak, per-restart-random salt: an unstable salt would re-hash the
  # same visitor across deployments and corrupt unique-visitor counts. The
  # secret must be a single, high-entropy value that stays constant for the life
  # of the deployment (generate once with `openssl rand -base64 48`).
  if Application.get_env(:tymeslot, :booking_analytics_enabled, false) do
    config :tymeslot,
           :analytics_salt_secret,
           System.get_env("ANALYTICS_SALT_SECRET") ||
             raise("""
             missing ANALYTICS_SALT_SECRET environment variable

             Booking analytics is enabled (config :tymeslot, :booking_analytics_enabled, true)
             but ANALYTICS_SALT_SECRET is not set. This secret keys the cookie-less
             visitor fingerprint and must be a stable, high-entropy value that does
             not change between deployments. Generate one once with:

                 openssl rand -base64 48

             and set it as a persistent environment variable. If you do not want
             booking analytics, leave it disabled and this variable is not required.
             """)
  end
end

# Configure mailer for non-production, non-test environments. `config/test.exs`
# pins the adapter to `Swoosh.Adapters.Test` so the test suite is deterministic
# regardless of the developer's ambient EMAIL_ADAPTER; runtime.exs must never
# override that pin.
if config_env() not in [:prod, :test] do
  # Default to smtp for self-hosted deployments. A set-but-blank
  # EMAIL_ADAPTER= is treated the same as unset, so it falls through to the
  # default below instead of Providers.build/1 raising on an unrecognised
  # provider name.
  email_adapter_default = Application.get_env(:tymeslot, :email_adapter_default, "smtp")

  email_adapter =
    "EMAIL_ADAPTER"
    |> System.get_env()
    |> Tymeslot.Mailer.Providers.blank_to_nil()
    |> Kernel.||(email_adapter_default)

  # A provider whose credentials are absent falls back to the local mailbox at
  # /dev/mailbox rather than failing to boot: an unconfigured development
  # machine should still start. Credentials that are present but malformed
  # still raise, here as in production.
  mailer_config =
    case Tymeslot.Mailer.Providers.build(email_adapter) do
      {:ok, config} ->
        config

      {:error, reason} ->
        Logger.info(
          "EMAIL_ADAPTER=#{String.trim(email_adapter)} is not configured (#{reason}); " <>
            "delivering to the local mailbox instead"
        )

        [adapter: Swoosh.Adapters.Local]
    end

  config :tymeslot, Tymeslot.Mailer, mailer_config
end

# Configure email settings
# On Cloudron, fall back to sendmail addon values if user hasn't set EMAIL_FROM_ADDRESS
from_email =
  System.get_env("EMAIL_FROM_ADDRESS") ||
    System.get_env("CLOUDRON_MAIL_FROM") ||
    if config_env() == :prod,
      do: raise("environment variable EMAIL_FROM_ADDRESS is missing"),
      else: "hello@tymeslot.app"

# Cloudron's CLOUDRON_MAIL_FROM_DISPLAY_NAME requires supportsDisplayName in the manifest
# (not currently set) — fall back to app name when sendmail addon is active
from_name =
  System.get_env("EMAIL_FROM_NAME") ||
    (System.get_env("CLOUDRON_MAIL_FROM") && "Tymeslot") ||
    if config_env() == :prod,
      do: raise("environment variable EMAIL_FROM_NAME is missing"),
      else: "Tymeslot"

config :tymeslot, :email,
  from_name: from_name,
  from_email: from_email,
  support_email: System.get_env("EMAIL_SUPPORT_ADDRESS") || from_email,
  contact_recipient: System.get_env("EMAIL_CONTACT_RECIPIENT") || from_email,
  domain:
    System.get_env("PHX_HOST") ||
      System.get_env("CLOUDRON_APP_DOMAIN") ||
      "tymeslot.app"

# Admin alerts — disabled by default. Self-hosters can opt in by setting
# ADMIN_ALERTS_ENABLED=true and ADMIN_ALERT_EMAIL=<recipient>. Both must be
# set for emails to be delivered. See CONTRIBUTING.md for how to share alerts
# with the project as error reports.
if System.get_env("ADMIN_ALERTS_ENABLED") in ["true", "1", "yes"] do
  config :tymeslot, :admin_alerts_enabled, true
end

case System.get_env("ADMIN_ALERT_EMAIL") do
  nil -> :ok
  "" -> :ok
  email -> config :tymeslot, :admin_alert_email, email
end

# Stripe Payment Configuration (optional for core, can be configured later)
if config_env() == :prod do
  stripe_secret_key = System.get_env("STRIPE_SECRET_KEY")

  if stripe_secret_key do
    config :stripity_stripe,
      api_key: stripe_secret_key

    # Stripe webhook secret (optional)
    stripe_webhook_secret = System.get_env("STRIPE_WEBHOOK_SECRET")

    if stripe_webhook_secret do
      config :tymeslot, :stripe_webhook_secret, stripe_webhook_secret
    else
      Logger.warning("STRIPE_WEBHOOK_SECRET not set — webhook signature verification disabled")
    end

    # Stripe Connect webhook secret (separate from the platform webhook secret)
    stripe_connect_webhook_secret = System.get_env("STRIPE_CONNECT_WEBHOOK_SECRET")

    if stripe_connect_webhook_secret do
      config :tymeslot, :stripe_connect_webhook_secret, stripe_connect_webhook_secret
    end
  end
end

# Self-host opt-in for the meeting-payments feature. Off by default — flipping
# MEETING_PAYMENTS_ENABLED=true requires the instance owner to register their
# instance as a Stripe platform and supply STRIPE_SECRET_KEY plus
# STRIPE_CONNECT_WEBHOOK_SECRET above. The optional application fee is taken
# from each charge in basis points (0–10000); defaults to 0 so no platform cut
# is taken unless the operator explicitly sets one.
case String.downcase(System.get_env("MEETING_PAYMENTS_ENABLED", "false")) do
  truthy when truthy in ["true", "1", "yes"] ->
    config :tymeslot, :meeting_payments_enabled, true

  _ ->
    :ok
end

case System.get_env("MEETING_PAYMENTS_DEFAULT_COUNTRY") do
  nil -> :ok
  "" -> :ok
  code -> config :tymeslot, :meeting_payments_default_country, String.downcase(code)
end

case System.get_env("MEETING_PAYMENTS_APPLICATION_FEE_BP") do
  nil ->
    :ok

  "" ->
    :ok

  raw ->
    case Integer.parse(raw) do
      {bp, _} when bp >= 0 and bp <= 10_000 ->
        config :tymeslot, :payment_application_fee_bp, bp

      _other ->
        raise """
        MEETING_PAYMENTS_APPLICATION_FEE_BP must be an integer between 0 and 10000
        (basis points: 100 = 1%). Got: #{inspect(raw)}
        """
    end
end

# Development/test environment Stripe configuration
if config_env() in [:dev, :test] do
  config :stripity_stripe,
    api_key: System.get_env("STRIPE_SECRET_KEY", "sk_test_fake")

  config :tymeslot, :stripe_webhook_secret, System.get_env("STRIPE_WEBHOOK_SECRET")

  config :tymeslot,
         :stripe_connect_webhook_secret,
         System.get_env("STRIPE_CONNECT_WEBHOOK_SECRET")
end

# Telegram integration feature flags (Core defaults)
# Shared bot mode: set TELEGRAM_BOT_TOKEN + TELEGRAM_BOT_USERNAME + TELEGRAM_WEBHOOK_SECRET.
# Presence of TELEGRAM_BOT_TOKEN enables shared bot mode automatically (TELEGRAM_ENABLED not needed).
# Own-bot mode: set only TELEGRAM_ENABLED=true; each user supplies their own bot token and chat ID.
telegram_bot_token = System.get_env("TELEGRAM_BOT_TOKEN")

if telegram_bot_token do
  config :tymeslot,
    telegram_notifications_allowed: true,
    telegram_shared_bot: true,
    telegram_bot_token: telegram_bot_token,
    telegram_bot_username: System.fetch_env!("TELEGRAM_BOT_USERNAME"),
    telegram_webhook_secret: System.fetch_env!("TELEGRAM_WEBHOOK_SECRET")
else
  config :tymeslot,
    telegram_notifications_allowed: System.get_env("TELEGRAM_ENABLED") == "true",
    telegram_shared_bot: false
end

# Slack integration feature flags (Core defaults)
# Webhook-URL mode: set SLACK_ENABLED=true; users paste their own Incoming Webhook URL.
# OAuth mode: set SLACK_CLIENT_ID + SLACK_CLIENT_SECRET; users connect via a Slack App.
# Presence of SLACK_CLIENT_ID also enables Slack notifications (webhook-URL mode still works).
slack_client_id = System.get_env("SLACK_CLIENT_ID")
slack_client_secret = System.get_env("SLACK_CLIENT_SECRET")
slack_enabled_flag = System.get_env("SLACK_ENABLED") == "true"

config :tymeslot,
  slack_notifications_allowed: slack_enabled_flag or not is_nil(slack_client_id),
  slack_oauth_available: not is_nil(slack_client_id) and not is_nil(slack_client_secret),
  slack_client_id: slack_client_id,
  slack_client_secret: slack_client_secret

config :tymeslot, registration_enabled: System.get_env("REGISTRATION_ENABLED", "true") == "true"
config :tymeslot, password_auth_enabled: System.get_env("PASSWORD_AUTH_ENABLED", "true") == "true"

# Default locale for visitors who express no preference — no `?locale=`, no
# session, no Accept-Language match. A self-hosted instance serving one country
# wants this set once at deploy time rather than per visitor.
#
# This sets `:locales`'s `:default`, which `Tymeslot.Locales.default_locale/0`
# reads, because that is the value the request pipeline actually resolves
# against. `config :tymeslot, TymeslotWeb.Gettext, default_locale:` cannot serve
# this purpose: Gettext reads a backend's `:default_locale` at compile time, so
# overriding it from a release has no effect on rendering.
#
# `default_from_env/1` returns nil when unset or blank and raises on a code this
# build cannot render. Keyword lists are deep merged, so `:supported` from
# config/config.exs is preserved and only `:default` is replaced.
default_locale = Tymeslot.Locales.default_from_env(System.get_env("DEFAULT_LOCALE"))

if default_locale do
  config :tymeslot, :locales, default: default_locale
end

# Social Authentication Configuration
# These environment variables control whether social login is enabled
#
# On Cloudron: auto-enable OAuth from OIDC addon unless explicitly disabled
cloudron_oidc_available? =
  System.get_env("DEPLOYMENT_TYPE") == "cloudron" and
    System.get_env("CLOUDRON_OIDC_CLIENT_ID") != nil

# Determine OAuth enabled state:
# 1. Explicit ENABLE_OAUTH_AUTH env var always wins
# 2. Cloudron OIDC addon auto-enables if present
# 3. Default: false
oauth_enabled =
  case System.get_env("ENABLE_OAUTH_AUTH") do
    "true" -> true
    "false" -> false
    nil -> cloudron_oidc_available?
    other -> raise ~s(ENABLE_OAUTH_AUTH must be "true" or "false", got: #{inspect(other)})
  end

config :tymeslot, :social_auth,
  google_enabled: System.get_env("ENABLE_GOOGLE_AUTH", "false") == "true",
  github_enabled: System.get_env("ENABLE_GITHUB_AUTH", "false") == "true",
  oauth_enabled: oauth_enabled

# Generic OAuth / OIDC Provider Configuration
# For SSO authentication with any OAuth2/OIDC-compliant identity provider
#
# On Cloudron: fall back to CLOUDRON_OIDC_* env vars when OAUTH_* vars are not set
oauth_client_id =
  System.get_env("OAUTH_CLIENT_ID") || System.get_env("CLOUDRON_OIDC_CLIENT_ID")

oauth_client_secret =
  System.get_env("OAUTH_CLIENT_SECRET") || System.get_env("CLOUDRON_OIDC_CLIENT_SECRET")

oauth_provider_url =
  System.get_env("OAUTH_PROVIDER_URL") || System.get_env("CLOUDRON_OIDC_ISSUER")

oauth_authorize_url =
  System.get_env("OAUTH_AUTHORIZE_URL") || System.get_env("CLOUDRON_OIDC_AUTH_ENDPOINT")

oauth_token_url =
  System.get_env("OAUTH_TOKEN_URL") || System.get_env("CLOUDRON_OIDC_TOKEN_ENDPOINT")

oauth_userinfo_url =
  System.get_env("OAUTH_USERINFO_URL") || System.get_env("CLOUDRON_OIDC_PROFILE_ENDPOINT")

config :tymeslot, :oauth_provider,
  client_id: oauth_client_id,
  client_secret: oauth_client_secret,
  site: oauth_provider_url,
  authorize_url: oauth_authorize_url,
  token_url: oauth_token_url,
  userinfo_url: oauth_userinfo_url,
  scope: System.get_env("OAUTH_SCOPE", "openid email profile"),
  allow_id_fallback: System.get_env("OAUTH_ALLOW_ID_FALLBACK", "false") == "true"

if oauth_enabled do
  required_oauth_vars = %{
    "OAUTH_CLIENT_ID / CLOUDRON_OIDC_CLIENT_ID" => oauth_client_id,
    "OAUTH_CLIENT_SECRET / CLOUDRON_OIDC_CLIENT_SECRET" => oauth_client_secret,
    "OAUTH_PROVIDER_URL / CLOUDRON_OIDC_ISSUER" => oauth_provider_url,
    "OAUTH_AUTHORIZE_URL / CLOUDRON_OIDC_AUTH_ENDPOINT" => oauth_authorize_url,
    "OAUTH_TOKEN_URL / CLOUDRON_OIDC_TOKEN_ENDPOINT" => oauth_token_url,
    "OAUTH_USERINFO_URL / CLOUDRON_OIDC_PROFILE_ENDPOINT" => oauth_userinfo_url
  }

  missing =
    required_oauth_vars
    |> Enum.filter(fn {_, val} -> is_nil(val) or String.trim(val) == "" end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()

  if missing != [] do
    raise """
    OAuth/OIDC is enabled but required environment variables are missing or empty:

      #{Enum.join(missing, "\n  ")}

    Set all required variables or disable OAuth with ENABLE_OAUTH_AUTH=false.
    See the OIDC/SSO documentation for configuration details.
    """
  end

  # Enforce HTTPS for OAuth URLs that carry secret material or security tokens.
  # Relative paths (no scheme) are allowed — they're resolved against the site URL.
  https_required_vars = %{
    "OAUTH_AUTHORIZE_URL / CLOUDRON_OIDC_AUTH_ENDPOINT" => oauth_authorize_url,
    "OAUTH_TOKEN_URL / CLOUDRON_OIDC_TOKEN_ENDPOINT" => oauth_token_url,
    "OAUTH_USERINFO_URL / CLOUDRON_OIDC_PROFILE_ENDPOINT" => oauth_userinfo_url
  }

  non_https =
    https_required_vars
    |> Enum.filter(fn {_, val} ->
      not is_nil(val) and
        not String.starts_with?(val, "https://") and
        String.starts_with?(val, "http://")
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()

  if non_https != [] do
    raise """
    OAuth/OIDC is enabled but the following URLs must use HTTPS (or be relative paths):

      #{Enum.join(non_https, "\n  ")}

    OAuth token and userinfo endpoints carry secret material (client credentials,
    access tokens) and must not be served over plaintext HTTP.
    """
  end

  if cloudron_oidc_available? and System.get_env("ENABLE_OAUTH_AUTH") == nil do
    Logger.info("Cloudron OIDC addon auto-enabled",
      issuer: oauth_provider_url,
      client_id: oauth_client_id
    )
  end
end

# reCAPTCHA configuration (runtime)
# Signup and booking protection are configurable and will automatically
# disable if keys are missing. The flags below seed the application config
# from the matching env vars; admins can override them at runtime via the
# admin settings UI (which writes through Tymeslot.AppSettings).

recaptcha_signup_min_score =
  case Float.parse(System.get_env("RECAPTCHA_SIGNUP_MIN_SCORE", "0.3")) do
    {score, _} -> score
    :error -> 0.3
  end

recaptcha_booking_min_score =
  case Float.parse(System.get_env("RECAPTCHA_BOOKING_MIN_SCORE", "0.3")) do
    {score, _} -> score
    :error -> 0.3
  end

recaptcha_signup_action = System.get_env("RECAPTCHA_SIGNUP_ACTION", "signup_form")
recaptcha_booking_action = System.get_env("RECAPTCHA_BOOKING_ACTION", "booking_form")

recaptcha_expected_hostnames =
  System.get_env("RECAPTCHA_EXPECTED_HOSTNAMES", "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))

config :tymeslot, :recaptcha,
  signup_min_score: recaptcha_signup_min_score,
  signup_action: recaptcha_signup_action,
  booking_min_score: recaptcha_booking_min_score,
  booking_action: recaptcha_booking_action,
  expected_hostnames: recaptcha_expected_hostnames

# The enabled flags are seeded from env in non-test environments only — test
# config sets them explicitly in config/test.exs so the
# developer shell can't accidentally enable reCAPTCHA for tests by exporting
# RECAPTCHA_SIGNUP_ENABLED.
if config_env() != :test do
  config :tymeslot, :recaptcha,
    signup_enabled: System.get_env("RECAPTCHA_SIGNUP_ENABLED", "false") == "true",
    booking_enabled: System.get_env("RECAPTCHA_BOOKING_ENABLED", "false") == "true"
end

# Webhook base URL for inbound push notifications from calendar providers.
# Required to enable Google Calendar push channels and Outlook Graph subscriptions.
# When unset or blank, push channel registration is silently skipped (integrations
# still work via polling fallback).
#
# A blank value is treated as unset: an empty string is truthy in Elixir, so deployment
# templates that pass `${WEBHOOK_BASE_URL:-}` would otherwise configure a host-less URL
# and generate broken notification endpoints like "/webhooks/outlook-calendar".
webhook_base_url = System.get_env("WEBHOOK_BASE_URL")

if webhook_base_url && String.trim(webhook_base_url) != "" do
  config :tymeslot, :webhook_base_url, String.trim(webhook_base_url)
end

# Self-host escape hatch for SSRF protection on calendar integrations. In :prod,
# outbound requests to CalDAV servers whose hostname resolves to a
# private/loopback/link-local address are blocked (Tymeslot.Security.SsrfGuard).
# Operators who intentionally run those integrations on a private network — the
# common self-hosting case — opt out by setting ALLOW_PRIVATE_IPS_FOR_CALENDAR=true.
#
# For backwards compatibility this also satisfies video, which it was originally
# documented as covering; ALLOW_PRIVATE_IPS_FOR_VIDEO below is the switch to
# reach for now.
#
# This does NOT relax webhook SSRF protection (Tymeslot.Webhooks.SsrfValidator);
# webhooks have their own switch (ALLOW_PRIVATE_IPS_FOR_WEBHOOKS below).
#
# Seeded from env in non-test environments only, so an exported shell var can't
# flip the default for the test suite (tests set the flag explicitly).
if config_env() != :test and
     System.get_env("ALLOW_PRIVATE_IPS_FOR_CALENDAR") in ["true", "1", "yes"] do
  config :tymeslot, :allow_private_ips_for_calendar, true
end

# Video-scoped sibling of the above, covering both self-hosted MiroTalk and the
# custom video link's reachability test. Set ALLOW_PRIVATE_IPS_FOR_VIDEO=true to
# run a meeting server on an internal network without relaxing calendar SSRF.
if config_env() != :test and
     System.get_env("ALLOW_PRIVATE_IPS_FOR_VIDEO") in ["true", "1", "yes"] do
  config :tymeslot, :allow_private_ips_for_video, true
end

# Webhook-scoped sibling of the above. In :prod, outbound webhook deliveries to
# a URL whose hostname resolves to a private/loopback/link-local address are
# blocked (Tymeslot.Webhooks.SsrfValidator). Operators who intentionally point
# webhooks at internal services opt out with ALLOW_PRIVATE_IPS_FOR_WEBHOOKS=true.
#
# Deliberately separate from ALLOW_PRIVATE_IPS_FOR_CALENDAR: relaxing calendar
# and video SSRF should not silently open outbound webhooks to internal hosts.
if config_env() != :test and
     System.get_env("ALLOW_PRIVATE_IPS_FOR_WEBHOOKS") in ["true", "1", "yes"] do
  config :tymeslot, :allow_private_ips_for_webhooks, true
end

# Base URL for docs hub links across the dashboard and the feature-announcement
# modal (TymeslotWeb.Live.Shared.DocsUrl, the single reader of this key).
# Defaults to the hosted docs site; a self-hoster running their own docs points
# this at it instead. A blank value is treated as unset for the same reason as
# WEBHOOK_BASE_URL above. A trailing slash is trimmed by the reader, not here.
docs_article_base_url = System.get_env("DOCS_ARTICLE_BASE_URL")

if docs_article_base_url && String.trim(docs_article_base_url) != "" do
  config :tymeslot, :docs_article_base_url, String.trim(docs_article_base_url)
end
