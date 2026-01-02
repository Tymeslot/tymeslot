import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

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
  deployment_type = System.get_env("DEPLOYMENT_TYPE")

  # Configure upload directory for production
  config :tymeslot, :upload_directory, "/app/data/uploads"
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

  # Resolve LiveView signing salt strictly at runtime (env or mounted file)
  live_view_signing_salt =
    case {System.get_env("LIVE_VIEW_SIGNING_SALT"), System.get_env("LIVE_VIEW_SIGNING_SALT_FILE")} do
      {nil, nil} ->
        raise "LIVE_VIEW_SIGNING_SALT is missing. Set LIVE_VIEW_SIGNING_SALT or LIVE_VIEW_SIGNING_SALT_FILE"

      {salt, nil} when is_binary(salt) ->
        trimmed = String.trim(salt)

        if trimmed == "" do
          raise "LIVE_VIEW_SIGNING_SALT cannot be blank"
        else
          trimmed
        end

      {_, file} when is_binary(file) ->
        path = String.trim(file)
        contents = String.trim(File.read!(path))

        if contents == "" do
          raise "LIVE_VIEW_SIGNING_SALT_FILE cannot be blank or point to an empty file"
        else
          contents
        end
    end

  # Determine the URL scheme based on deployment type
  url_scheme =
    case deployment_type do
      "cloudron" -> "https"  # Cloudron reverse proxy handles HTTPS
      "docker" -> "http"     # Docker without reverse proxy (unless configured externally)
      "main" -> "https"      # Main production deployment uses HTTPS
      _ -> "https"           # Everything else defaults to HTTPS for safety
    end

  # For Cloudron, use port 80 internally (reverse proxy is on 443)
  # For other deployments, adjust as needed
  url_port =
    case deployment_type do
      "cloudron" -> 80
      _ -> 443
    end

  config :tymeslot, TymeslotWeb.Endpoint,
    url: [host: host, port: url_port, scheme: url_scheme],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base,
    check_origin: allowed_origins,
    live_view: [signing_salt: live_view_signing_salt]

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :tymeslot, TymeslotWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :tymeslot, TymeslotWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Also, you may need to configure the Swoosh API client of your choice if you
  # are not using SMTP. Here is an example of the configuration:
  #
  #     config :tymeslot, Tymeslot.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # For this example you need include a HTTP client required by Swoosh API client.
  # Swoosh supports Hackney and Finch out of the box:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Hackney
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.

  # Database configuration based on deployment type (already defined above)
  database_config =
    case deployment_type do
      "cloudron" ->
        [
          url: System.get_env("CLOUDRON_POSTGRESQL_URL"),
          username: System.get_env("CLOUDRON_POSTGRESQL_USERNAME"),
          password: System.get_env("CLOUDRON_POSTGRESQL_PASSWORD"),
          hostname: System.get_env("CLOUDRON_POSTGRESQL_HOST"),
          port: System.get_env("CLOUDRON_POSTGRESQL_PORT"),
          database: System.get_env("CLOUDRON_POSTGRESQL_DATABASE"),
          pool_size: String.to_integer(System.get_env("DATABASE_POOL_SIZE") || "100"),
          idle_interval: 60_000,
          queue_target: 5000,
          queue_interval: 10000
        ]

      "main" ->
        [
          url: System.get_env("CLOUDRON_POSTGRESQL_URL"),
          username: System.get_env("CLOUDRON_POSTGRESQL_USERNAME"),
          password: System.get_env("CLOUDRON_POSTGRESQL_PASSWORD"),
          hostname: System.get_env("CLOUDRON_POSTGRESQL_HOST"),
          port: System.get_env("CLOUDRON_POSTGRESQL_PORT"),
          database: System.get_env("CLOUDRON_POSTGRESQL_DATABASE"),
          pool_size: String.to_integer(System.get_env("DATABASE_POOL_SIZE") || "100"),
          idle_interval: 60_000,
          queue_target: 5000,
          queue_interval: 10000
        ]

      "docker" ->
        # The embedded Postgres in Docker uses the default max_connections=100.
        # Keep the default pool size low to avoid exhausting connections during boot.
        [
          hostname: "localhost",
          port: 5432,
          database: System.get_env("POSTGRES_DB", "tymeslot"),
          username: System.get_env("POSTGRES_USER", "tymeslot"),
          password:
            System.get_env("POSTGRES_PASSWORD") ||
              raise("POSTGRES_PASSWORD environment variable is missing"),
          pool_size: String.to_integer(System.get_env("DATABASE_POOL_SIZE") || "10"),
          idle_interval: 60_000,
          queue_target: 5000,
          queue_interval: 10000
        ]

      nil ->
        raise """
        DEPLOYMENT_TYPE environment variable must be set to either 'cloudron', 'main', or 'docker'.
        """

      _ ->
        raise """
        DEPLOYMENT_TYPE must be either 'cloudron', 'main', or 'docker', got: #{deployment_type}
        """
    end

  config :tymeslot, Tymeslot.Repo, database_config

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
  config :tymeslot, Oban,
    repo: Tymeslot.Repo,
    plugins: [
      Oban.Plugins.Pruner,
      {Oban.Plugins.Cron,
       crontab: [
         # Run daily at 03:15 UTC; adjust if you prefer a different time
         {"15 3 * * *", Tymeslot.Workers.ExpiredSessionCleanupWorker}
       ]}
    ],
    queues: [
      default: 10,
      emails: 5,
      video_rooms: 3,
      calendar_events: 3,
      calendar_integrations: 2
    ]

  # Configure tzdata to use writable directory in production
  tzdata_dir = "/app/data/tzdata"

  config :tzdata, :data_dir, tzdata_dir

  # Configure mailer based on EMAIL_ADAPTER setting
  # Default to postmark for main deployment, test for others (docker/cloudron testing)
  email_adapter_default =
    case deployment_type do
      "main" -> "postmark"
      _ -> "test"
    end

  email_adapter = System.get_env("EMAIL_ADAPTER", email_adapter_default)

  mailer_config =
    case email_adapter do
      "smtp" ->
        [
          adapter: Swoosh.Adapters.SMTP,
          relay: System.get_env("SMTP_HOST"),
          port: String.to_integer(System.get_env("SMTP_PORT", "587")),
          username: System.get_env("SMTP_USERNAME"),
          password: System.get_env("SMTP_PASSWORD"),
          tls: :if_available,
          auth: :if_available
        ]

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
  email_adapter = System.get_env("EMAIL_ADAPTER", "postmark")

  mailer_config =
    case email_adapter do
      "smtp" ->
        if System.get_env("SMTP_HOST") do
          [
            adapter: Swoosh.Adapters.SMTP,
            relay: System.get_env("SMTP_HOST"),
            port: String.to_integer(System.get_env("SMTP_PORT", "587")),
            username: System.get_env("SMTP_USERNAME"),
            password: System.get_env("SMTP_PASSWORD"),
            tls: :if_available,
            auth: :if_available
          ]
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
    (if config_env() == :prod,
      do: raise("environment variable EMAIL_FROM_ADDRESS is missing"),
      else: "hello@tymeslot.app")

from_name =
  System.get_env("EMAIL_FROM_NAME") ||
    (if config_env() == :prod,
      do: raise("environment variable EMAIL_FROM_NAME is missing"),
      else: "Tymeslot")

phx_host =
  System.get_env("PHX_HOST") ||
    (if config_env() == :prod,
      do: raise("environment variable PHX_HOST is missing"),
      else: "tymeslot.app")

config :tymeslot, :email,
  from_name: from_name,
  from_email: from_email,
  support_email: System.get_env("EMAIL_SUPPORT_ADDRESS") || from_email,
  contact_recipient: System.get_env("EMAIL_CONTACT_RECIPIENT") || from_email,
  domain: phx_host

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

# Integration configurations are now managed through the database
# Calendar and video integrations can be configured in the dashboard at /dashboard
