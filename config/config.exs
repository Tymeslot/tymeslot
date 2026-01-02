# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :tymeslot,
  ecto_repos: [Tymeslot.Repo],
  generators: [timestamp_type: :utc_datetime],
  app_name: "Tymeslot"

# Configure HTTP client timeouts for different operations (optional)
# Times are in milliseconds. These can be overridden in runtime.exs
config :tymeslot, :http_timeouts, %{
  get: [timeout: 30_000, recv_timeout: 30_000],
  put: [timeout: 45_000, recv_timeout: 45_000],
  delete: [timeout: 45_000, recv_timeout: 45_000],
  report: [timeout: 60_000, recv_timeout: 60_000]
}

# Configures the endpoint
# NOTE: The base config defaults to HTTP for localhost. Environment-specific configs
# (dev.exs, test.exs) override this with appropriate scheme/port/host. Production
# scheme/host/port is set dynamically in runtime.exs based on DEPLOYMENT_TYPE and
# environment variables. This base config ensures generated URLs (email links, redirects)
# have a sensible fallback even if env config is incomplete.
config :tymeslot, TymeslotWeb.Endpoint,
  url: [host: "localhost", scheme: "http"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TymeslotWeb.ErrorHTML, json: TymeslotWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Tymeslot.PubSub

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :tymeslot, Tymeslot.Mailer, adapter: Swoosh.Adapters.Local

# Configure Swoosh API client (used by Postmark adapter)
config :swoosh, :api_client, Swoosh.ApiClient.Hackney

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  tymeslot: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
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
  scheduling: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/scheduling.css
      --output=../priv/static/assets/scheduling.css
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

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :action,
    :args,
    :attempt,
    :attempts,
    :attendee_result,
    :attendee_sent,
    :attrs,
    :backoff_ms,
    :base_url,
    :breaker,
    :breaker_name,
    :bucket_key,
    :calendar_count,
    :calendar_names,
    :calendar_path,
    :calendar_paths,
    :calendars,
    :changed,
    :conflicting_count,
    :content,
    :correlation_id,
    :count,
    :current_count,
    :date,
    :deleted_count,
    :datetime,
    :delay_ms,
    :details,
    :duration_ms,
    :end_date,
    :end_time,
    :error,
    :errors,
    :event_count,
    :event_data,
    :event_id,
    :failed,
    :failures,
    :free,
    :has_meeting_url,
    :has_start,
    :identifier,
    :in_use,
    :input_length,
    :ip,
    :key,
    :keys,
    :limit,
    :max_allowed,
    :max_attempts,
    :max_retries,
    :meeting_id,
    :meeting_uid,
    :meeting_url,
    :method,
    :month,
    :name,
    :new_state,
    :new_time,
    :old_state,
    :old_time,
    :operation,
    :organizer_email,
    :organizer_result,
    :organizer_sent,
    :organizer_user_id,
    :original_end,
    :original_length,
    :original_start,
    :param_keys,
    :params_count,
    :parser,
    :pattern,
    :pattern_detected,
    :pid,
    :pool,
    :queue,
    :reason,
    :removed,
    :requested_end,
    :response_body,
    :requested_start,
    :result,
    :role,
    :room,
    :room_id,
    :sanitized_length,
    :scheduled_at,
    :send_emails,
    :sender_email,
    :sent,
    :size_bytes,
    :snooze_seconds,
    :stacktrace,
    :start_date,
    :start_time,
    :status,
    :status_code,
    :stripped_length,
    :subject,
    :missing,
    :need_organizer,
    :need_attendee,
    :submission_token,
    :successful,
    :text,
    :summary,
    :table,
    :threshold,
    :time,
    :time_until,
    :timeout_ms,
    :timestamp,
    :timezone,
    :total_attempts,
    :timezone_length,
    :title,
    :total_ranges,
    :uid,
    :url,
    :user_agent_hash,
    :user_id,
    :user_identifier,
    :username,
    :value_type,
    :window_ms,
    :year,
    :to,
    :field,
    :participant,
    :provider,
    :event,
    :additional_data,
    :valid,
    :provider_type,
    :message,
    :integration_id,
    :date_range,
    :type,
    :category,
    :severity,
    :audit_id,
    :resource_type,
    :resource_id,
    :context,
    :evicted_entries,
    :entries_removed,
    :stuck_jobs_cleaned,
    :old_jobs_deleted,
    :retention_days,
    :states,
    :threshold_hours,
    :job_id,
    :pattern_type,
    :error_type,
    :from,
    :ip_address,
    :new_email,
    :new_sent,
    :old_email,
    :old_sent,
    :token,
    :user_agent,
    :score,
    :hostname,
    :expected_action,
    :expected_hostnames,
    :hint,
    :body,
    :response,
    :event_type,
    :max_length,
    :original_bytes,
    :max_input_bytes
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure timezone database
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

# Integration configurations are now managed through the database
# Calendar and video integrations can be configured in the dashboard at /dashboard

# Scheduling configuration has been moved to the database (profiles table)
# Users can configure their scheduling preferences in the dashboard

# Authentication configuration
config :tymeslot, :auth, success_redirect_path: "/dashboard"

# Input validation configuration
config :tymeslot, :field_validation,
  email_max_length: 254,
  name_min_length: 2,
  name_max_length: 100,
  text_min_length: 1,
  text_max_length: 500,
  message_min_length: 10,
  message_max_length: 2000,
  universal_max_length: 10_000,
  # Authentication-specific limits
  password_min_length: 8,
  password_max_length: 80,
  full_name_max_length: 100

# Google OAuth Configuration
# These can be overridden by environment variables in runtime.exs
config :tymeslot, :google_oauth,
  client_id: System.get_env("GOOGLE_CLIENT_ID"),
  client_secret: System.get_env("GOOGLE_CLIENT_SECRET"),
  state_secret: System.get_env("GOOGLE_STATE_SECRET")

# Outlook OAuth Configuration
# These can be overridden by environment variables in runtime.exs
config :tymeslot, :outlook_oauth,
  client_id: System.get_env("OUTLOOK_CLIENT_ID"),
  client_secret: System.get_env("OUTLOOK_CLIENT_SECRET"),
  state_secret: System.get_env("OUTLOOK_STATE_SECRET")

# Social Authentication Configuration
# Controls whether users can sign up/log in with social providers
# These flags default to false and can be overridden in runtime.exs
config :tymeslot, :social_auth,
  google_enabled: System.get_env("ENABLE_GOOGLE_AUTH", "false") == "true",
  github_enabled: System.get_env("ENABLE_GITHUB_AUTH", "false") == "true"

# reCAPTCHA configuration is defined entirely in runtime.exs
# (all settings come from environment variables with sensible defaults)

# Provider enable/disable switches (single source of truth)
# Toggle providers on/off centrally without code changes
config :tymeslot, :video_providers, %{
  mirotalk: [enabled: true],
  google_meet: [enabled: true],
  teams: [enabled: false],
  custom: [enabled: true]
}

config :tymeslot, :calendar_providers, %{
  caldav: [enabled: true],
  radicale: [enabled: true],
  nextcloud: [enabled: true],
  google: [enabled: true],
  outlook: [enabled: false],
  debug: [enabled: false]
}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
