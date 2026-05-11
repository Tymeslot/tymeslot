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

# Helper to safely parse integers from environment variables with validation
parse_int = fn var, default ->
  case System.get_env(var) do
    nil ->
      default

    value ->
      case Integer.parse(value) do
        {int, _} when int >= 1 and int <= 65535 ->
          int

        {int, _} ->
          raise """
          Invalid #{var}: #{int}
          Port must be between 1-65535
          """

        :error ->
          raise """
          Invalid #{var}: #{inspect(value)}
          Must be a valid integer
          """
      end
  end
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

  # Database configuration helper
  get_database_config = fn deployment_type, overrides ->
    base_config =
      case deployment_type do
        "cloudron" ->
          [
            url: System.get_env("CLOUDRON_POSTGRESQL_URL"),
            username: System.get_env("CLOUDRON_POSTGRESQL_USERNAME"),
            password: System.get_env("CLOUDRON_POSTGRESQL_PASSWORD"),
            hostname: System.get_env("CLOUDRON_POSTGRESQL_HOST"),
            port: System.get_env("CLOUDRON_POSTGRESQL_PORT"),
            database: System.get_env("CLOUDRON_POSTGRESQL_DATABASE"),
            pool_size: parse_int.("DATABASE_POOL_SIZE", 60),
            idle_interval: 60_000,
            queue_target: 5000,
            queue_interval: 10000
          ]

        "docker" ->
          # Docker deployment with embedded or external PostgreSQL
          # Default pool_size=60 supports high Oban concurrency (~47 max concurrent workers)
          # Note: Ensure PostgreSQL max_connections >= 100 (Docker embedded Postgres default)
          # To increase: Add `-c max_connections=150` to postgres command in docker-compose.yml
          [
            hostname: System.get_env("DATABASE_HOST", "localhost"),
            port: parse_int.("DATABASE_PORT", 5432),
            database: System.get_env("POSTGRES_DB", "tymeslot"),
            username: System.get_env("POSTGRES_USER", "tymeslot"),
            password:
              System.get_env("POSTGRES_PASSWORD") ||
                raise("POSTGRES_PASSWORD environment variable is missing"),
            pool_size: parse_int.("DATABASE_POOL_SIZE", 60),
            idle_interval: 60_000,
            queue_target: 5000,
            queue_interval: 10000
          ]
      end

    Keyword.merge(base_config, overrides)
  end

  config :tymeslot, Tymeslot.Repo, get_database_config.(deployment_type, [])

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
    plugins: [
      {Oban.Plugins.Pruner, max_age: 604_800},
      {Oban.Plugins.Cron,
       crontab: [
         # Run every 30 minutes for Oban maintenance
         {"*/30 * * * *", Tymeslot.Workers.ObanMaintenanceWorker},
         # Run every hour for queue health monitoring
         {"0 * * * *", Tymeslot.Workers.ObanQueueMonitorWorker},
         # Run daily at 02:45 UTC for video room recovery scan
         {"45 2 * * *", Tymeslot.Workers.VideoRoomRecoveryScanWorker},
         # Run daily at 03:15 UTC
         {"15 3 * * *", Tymeslot.Workers.ExpiredSessionCleanupWorker},
         # Run daily at 02:00 UTC to renew expiring webhook channels
         {"0 2 * * *", Tymeslot.Workers.RenewWebhookChannelsWorker},
         # Run every 15 min; CalDAV tier-aware filtering decides which integrations sync
         {"*/15 * * * *", Tymeslot.Workers.FallbackSyncSweepWorker},
         # Run daily at 04:00 UTC for webhook cleanup
         {"0 4 * * *", Tymeslot.Workers.WebhookCleanupWorker, args: %{retention_days: 60}},
         # Run every 6 hours to detect silent/dead webhook channels
         {"0 */6 * * *", Tymeslot.Workers.DeadChannelAlertWorker},
         # Run daily at 03:30 UTC to prune old/inactive calendar event cache
         {"30 3 * * *", Tymeslot.Workers.CalendarCachePruneWorker},
         # Run daily at 05:00 UTC to auto-pause integrations stuck unhealthy past the configured cutoff
         {"0 5 * * *", Tymeslot.Workers.IntegrationAutoPauseWorker},
         # Run every 15 min to reconcile awaiting_payment meetings whose webhook never arrived
         {"*/15 * * * *", Tymeslot.MeetingPayments.Workers.ReconcileAwaitingPayments}
       ]}
    ]

  # Configure mailer based on EMAIL_ADAPTER setting
  # Default to smtp for self-hosted deployments
  # On Cloudron: auto-detect sendmail addon when EMAIL_ADAPTER is not explicitly set
  email_adapter_explicit = System.get_env("EMAIL_ADAPTER")

  # Helper: build standard SMTP config from SMTP_* env vars
  build_smtp_config = fn ->
    smtp_host = System.get_env("SMTP_HOST")
    smtp_username = System.get_env("SMTP_USERNAME")
    smtp_password = System.get_env("SMTP_PASSWORD")

    if smtp_host != nil and String.trim(smtp_host) == "" do
      raise "SMTP_HOST cannot be empty or whitespace-only"
    end

    if smtp_username != nil and String.trim(smtp_username) == "" do
      raise "SMTP_USERNAME cannot be empty or whitespace-only"
    end

    if smtp_password != nil and String.trim(smtp_password) == "" do
      raise "SMTP_PASSWORD cannot be empty or whitespace-only"
    end

    Tymeslot.Mailer.SMTPConfig.build(
      host: smtp_host,
      port: parse_int.("SMTP_PORT", 587),
      username: smtp_username,
      password: smtp_password
    )
  end

  mailer_config =
    cond do
      # Explicit adapter always wins — user knows what they want
      email_adapter_explicit != nil ->
        case email_adapter_explicit do
          "smtp" ->
            build_smtp_config.()

          "postmark" ->
            [adapter: Swoosh.Adapters.Postmark, api_key: System.get_env("POSTMARK_API_KEY")]

          "test" ->
            [adapter: Swoosh.Adapters.Test]

          "local" ->
            [adapter: Swoosh.Adapters.Test]

          _ ->
            [adapter: Swoosh.Adapters.Test]
        end

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
        build_smtp_config.()
    end

  config :tymeslot, Tymeslot.Mailer, mailer_config
end

# Configure mailer for non-production environments
if config_env() != :prod do
  # Default to smtp for self-hosted deployments
  email_adapter_default = Application.get_env(:tymeslot, :email_adapter_default, "smtp")
  email_adapter = System.get_env("EMAIL_ADAPTER", email_adapter_default)

  mailer_config =
    case email_adapter do
      "smtp" ->
        # In non-production, only configure SMTP if SMTP_HOST is set and non-empty
        # Otherwise fall back to Local adapter for development
        smtp_host = System.get_env("SMTP_HOST")

        if smtp_host != nil and String.trim(smtp_host) != "" do
          smtp_username = System.get_env("SMTP_USERNAME")
          smtp_password = System.get_env("SMTP_PASSWORD")

          # Check for empty strings
          if smtp_username != nil and String.trim(smtp_username) == "" do
            raise "SMTP_USERNAME cannot be empty or whitespace-only"
          end

          if smtp_password != nil and String.trim(smtp_password) == "" do
            raise "SMTP_PASSWORD cannot be empty or whitespace-only"
          end

          # Use shared SMTP configuration module
          # This validates all required fields and handles SSL/TLS/STARTTLS setup
          # It also trims whitespace from host and validates all input types
          Tymeslot.Mailer.SMTPConfig.build(
            host: smtp_host,
            port: parse_int.("SMTP_PORT", 587),
            username: smtp_username,
            password: smtp_password
          )
        else
          [adapter: Swoosh.Adapters.Local]
        end

      "postmark" ->
        if System.get_env("POSTMARK_API_KEY") do
          [
            adapter: Swoosh.Adapters.Postmark,
            api_key: System.get_env("POSTMARK_API_KEY")
          ]
        else
          [adapter: Swoosh.Adapters.Local]
        end

      _ ->
        if System.get_env("POSTMARK_API_KEY") do
          [
            adapter: Swoosh.Adapters.Postmark,
            api_key: System.get_env("POSTMARK_API_KEY")
          ]
        else
          [adapter: Swoosh.Adapters.Local]
        end
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
      IO.warn("STRIPE_WEBHOOK_SECRET not set - webhook signature verification disabled")
    end

    # Stripe Connect webhook secret (separate from the platform webhook secret)
    stripe_connect_webhook_secret = System.get_env("STRIPE_CONNECT_WEBHOOK_SECRET")

    if stripe_connect_webhook_secret do
      config :tymeslot, :stripe_connect_webhook_secret, stripe_connect_webhook_secret
    end
  end

  # Trial period configuration (default 7 days)
  config :tymeslot, :trial_period_days, parse_int.("TRIAL_PERIOD_DAYS", 7)
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

  # Trial period configuration (default 7 days)
  config :tymeslot, :trial_period_days, parse_int.("TRIAL_PERIOD_DAYS", 7)
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

config :tymeslot, registration_enabled: System.get_env("REGISTRATION_ENABLED", "true") == "true"
config :tymeslot, password_auth_enabled: System.get_env("PASSWORD_AUTH_ENABLED", "true") == "true"

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
# Signup and booking protection are configurable and will automatically disable if keys are missing.
# RECAPTCHA_SIGNUP_ENABLED and RECAPTCHA_BOOKING_ENABLED are read directly by the respective
# enabled?() functions for runtime toggling support (useful for emergency disables during
# Google API outages without redeployment).

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

# Webhook base URL for inbound push notifications from calendar providers.
# Required to enable Google Calendar push channels and Outlook Graph subscriptions.
# When unset, push channel registration is silently skipped (integrations still work
# via polling fallback).
if webhook_base_url = System.get_env("WEBHOOK_BASE_URL") do
  config :tymeslot, :webhook_base_url, webhook_base_url
end
