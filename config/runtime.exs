import Config

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

if config_env() == :prod do
  # Set environment for runtime detection
  config :tymeslot, :environment, :prod

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

  host = System.get_env("PHX_HOST")
  port = String.to_integer(System.get_env("PORT") || "4000")

  # Allowed origins for LiveView WebSocket (align with CSP 'connect-src' and site origin)
  allowed_origins =
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
    check_origin: allowed_origins

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
         # Run daily at 04:00 UTC for webhook cleanup
         {"0 4 * * *", Tymeslot.Workers.WebhookCleanupWorker, args: %{retention_days: 60}}
       ]}
    ]

  # Configure tzdata to use writable directory in production
  tzdata_dir = "/app/data/tzdata"

  config :tzdata, :data_dir, tzdata_dir

  # Configure mailer based on EMAIL_ADAPTER setting
  # Default to smtp for self-hosted deployments
  # Can be overridden with EMAIL_ADAPTER environment variable
  email_adapter_default = Application.get_env(:tymeslot, :email_adapter_default, "smtp")
  email_adapter = System.get_env("EMAIL_ADAPTER", email_adapter_default)

  mailer_config =
    case email_adapter do
      "smtp" ->
        # Validate SMTP environment variables before passing to config builder
        smtp_host = System.get_env("SMTP_HOST")
        smtp_username = System.get_env("SMTP_USERNAME")
        smtp_password = System.get_env("SMTP_PASSWORD")

        # Check for empty strings (System.get_env returns nil if unset, but user might set to "")
        if smtp_host != nil and String.trim(smtp_host) == "" do
          raise "SMTP_HOST cannot be empty or whitespace-only"
        end

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

      "postmark" ->
        [
          adapter: Swoosh.Adapters.Postmark,
          api_key: System.get_env("POSTMARK_API_KEY")
        ]

      "test" ->
        [
          adapter: Swoosh.Adapters.Test
        ]

      "local" ->
        # Local adapter only works in dev, fallback to test in production
        [
          adapter: Swoosh.Adapters.Test
        ]

      _ ->
        [
          adapter: Swoosh.Adapters.Test
        ]
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
from_email =
  System.get_env("EMAIL_FROM_ADDRESS") ||
    if config_env() == :prod,
      do: raise("environment variable EMAIL_FROM_ADDRESS is missing"),
      else: "hello@tymeslot.app"

from_name =
  System.get_env("EMAIL_FROM_NAME") ||
    if config_env() == :prod,
      do: raise("environment variable EMAIL_FROM_NAME is missing"),
      else: "Tymeslot"

phx_host =
  System.get_env("PHX_HOST") ||
    if config_env() == :prod,
      do: raise("environment variable PHX_HOST is missing"),
      else: "tymeslot.app"

config :tymeslot, :email,
  from_name: from_name,
  from_email: from_email,
  support_email: System.get_env("EMAIL_SUPPORT_ADDRESS") || from_email,
  contact_recipient: System.get_env("EMAIL_CONTACT_RECIPIENT") || from_email,
  domain: phx_host

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
  end

  # Trial period configuration (default 7 days)
  config :tymeslot, :trial_period_days, parse_int.("TRIAL_PERIOD_DAYS", 7)
end

# Development/test environment Stripe configuration
if config_env() in [:dev, :test] do
  config :stripity_stripe,
    api_key: System.get_env("STRIPE_SECRET_KEY", "sk_test_fake")

  config :tymeslot, :stripe_webhook_secret, System.get_env("STRIPE_WEBHOOK_SECRET")

  # Trial period configuration (default 7 days)
  config :tymeslot, :trial_period_days, parse_int.("TRIAL_PERIOD_DAYS", 7)
end

# Social Authentication Configuration
# These environment variables control whether social login is enabled
config :tymeslot, :social_auth,
  google_enabled: System.get_env("ENABLE_GOOGLE_AUTH", "false") == "true",
  github_enabled: System.get_env("ENABLE_GITHUB_AUTH", "false") == "true"

# reCAPTCHA configuration (runtime)
# Signup protection is configurable and will automatically disable itself if keys are missing.
# RECAPTCHA_SIGNUP_ENABLED is read directly by signup_enabled?() for runtime toggling support
# (useful for emergency disables during Google API outages without redeployment).

recaptcha_signup_min_score =
  case Float.parse(System.get_env("RECAPTCHA_SIGNUP_MIN_SCORE", "0.3")) do
    {score, _} -> score
    :error -> 0.3
  end

recaptcha_signup_action = System.get_env("RECAPTCHA_SIGNUP_ACTION", "signup_form")

recaptcha_expected_hostnames =
  System.get_env("RECAPTCHA_EXPECTED_HOSTNAMES", "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))

config :tymeslot, :recaptcha,
  signup_min_score: recaptcha_signup_min_score,
  signup_action: recaptcha_signup_action,
  expected_hostnames: recaptcha_expected_hostnames
