import Config

# Configure environment
config :tymeslot, environment: :test, test_mode: true

# Reduce bcrypt cost for tests — default log_rounds (12) adds ~200-400ms per
# password hash, which compounds across hundreds of factory user inserts.
config :bcrypt_elixir, log_rounds: 4

# Disable legal acceptance gate in tests
config :tymeslot, enforce_legal_acceptance_gate: false

# Override SaaS config: Core tests must not enforce legal agreements
config :tymeslot, enforce_legal_agreements: false

# Force Core to use Tymeslot.PubSub in tests
config :tymeslot, :force_app_pubsub_in_test, true
config :tymeslot, :pubsub_name, Tymeslot.PubSub

# Force core router for tests
config :tymeslot, :router, TymeslotWeb.Router

# Configure upload directory for tests
config :tymeslot, :upload_directory, Path.expand("../test/uploads", __DIR__)

config :tymeslot, TymeslotWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("TEST_PORT") || "4002")],
  url: [
    host: "localhost",
    port: String.to_integer(System.get_env("TEST_PORT") || "4002"),
    scheme: "http"
  ],
  secret_key_base:
    System.get_env("SECRET_KEY_BASE") ||
      "j47WN/+e1mzK5Volysi74F0YKzItGcdYUBq3T5QjmnZDcAnsAJE28y5XCysI66kP",
  live_view: [signing_salt: "test_liveview_signing_salt"],
  session_signing_salt: "test_session_signing_salt",
  server: false

# Configure the database
default_pool_size = min(max(System.schedulers_online() * 2, 5), 10)

test_pool_size =
  case System.get_env("TEST_DB_POOL_SIZE") do
    nil ->
      default_pool_size

    value ->
      case Integer.parse(value) do
        {int, _} -> int
        :error -> default_pool_size
      end
  end

config :tymeslot, Tymeslot.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "tymeslot_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: test_pool_size,
  queue_target: 10_000,
  queue_interval: 10_000

# Configure Oban for testing
# Queues are loaded at runtime in application.ex from :oban_queues config
config :tymeslot, Oban,
  repo: Tymeslot.Repo,
  plugins: [{Oban.Plugins.Pruner, max_age: 3_600}],
  testing: :manual

# In test we don't send emails
config :tymeslot, Tymeslot.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client
config :swoosh, :api_client, false

# Print only warnings and errors during test, but show structured metadata
# so test failures and capture_log/1 output retain correlation_id / user_id.
config :logger, level: :warning

config :logger, :default_formatter,
  format: "[$level] $message $metadata\n",
  metadata: [:request_id, :user_id, :correlation_id, :event, :domain, :reason]

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Mock configuration
config :tymeslot, :calendar_module, Tymeslot.CalendarMock
config :tymeslot, :calendar_client_module, Tymeslot.RadicaleClientMock
config :tymeslot, :mirotalk_api_module, Tymeslot.MiroTalkAPIMock
config :tymeslot, :email_service_module, Tymeslot.EmailServiceMock
config :tymeslot, :google_calendar_api_module, GoogleCalendarAPIMock
config :tymeslot, :outlook_calendar_api_module, OutlookCalendarAPIMock
config :tymeslot, :google_calendar_oauth_helper, Tymeslot.GoogleOAuthHelperMock
config :tymeslot, :outlook_calendar_oauth_helper, Tymeslot.OutlookOAuthHelperMock
config :tymeslot, :teams_oauth_helper, Tymeslot.TeamsOAuthHelperMock
config :tymeslot, :zoom_oauth_helper, Tymeslot.ZoomOAuthHelperMock
config :tymeslot, :http_client_module, Tymeslot.HTTPClientMock
config :tymeslot, :req_test_plug, {Req.Test, :tymeslot_http}
config :tymeslot, :email_service, Tymeslot.EmailServiceMock
config :tymeslot, :transcoder, Tymeslot.Media.TranscoderMock
config :tymeslot, :health_check_module, Tymeslot.Integrations.HealthCheckMock

# MiroTalk test configuration
config :tymeslot, :mirotalk_api,
  api_key: "test-api-key",
  base_url: "https://test.mirotalk.com"

# Configure email settings for test
from_email = System.get_env("EMAIL_FROM_ADDRESS") || "hello@tymeslot.app"

config :tymeslot, :email,
  from_name: System.get_env("EMAIL_FROM_NAME") || "Tymeslot",
  from_email: from_email,
  support_email: System.get_env("EMAIL_SUPPORT_ADDRESS") || from_email,
  contact_recipient: System.get_env("EMAIL_CONTACT_RECIPIENT") || from_email,
  domain: System.get_env("PHX_HOST") || "tymeslot.app"

# Configure radicale for test
config :tymeslot, :radicale,
  url: "http://localhost:5232",
  username: "test",
  password: "test",
  calendar_path: "/test/calendar.ics/"

# Configure auth for test
config :tymeslot, :auth, success_redirect_path: "/dashboard"

# OAuth state secrets for test (signs/validates the `state` parameter).
# Tests typically mock State.validate/2, but OAuthStateGuard still reads
# these configs to pass them through, so they must be present.
config :tymeslot, :google_oauth, state_secret: "test-google-state-secret"
config :tymeslot, :outlook_oauth, state_secret: "test-outlook-state-secret"

# Analytics fingerprint salt secret — fixed value so fingerprint hashes are
# stable across test runs on the same day.
config :tymeslot, :analytics_salt_secret, "test_analytics_salt_secret_fixed_for_repeatability"

# Booking analytics is enabled by default in the test suite so the analytics
# tests exercise the live path. Tests covering the disabled path override this
# per-test with `Application.put_env/3`.
config :tymeslot, :booking_analytics_enabled, true

# Enable all providers for testing
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
  mailbox_org: [enabled: true],
  baikal: [enabled: true],
  google: [enabled: true],
  outlook: [enabled: true],
  demo: [enabled: false],
  debug: [enabled: false]
}

# Configure reCAPTCHA for tests
config :tymeslot, :recaptcha, signup_enabled: false, booking_enabled: false

# Payment system configuration for tests
config :tymeslot, :stripe_provider, Tymeslot.Payments.StripeMock
config :tymeslot, :subscription_manager, Tymeslot.Payments.SubscriptionManagerMock
config :tymeslot, :stripe_adapter, Tymeslot.MeetingPayments.StripeAdapterMock
config :tymeslot, :show_branding, true
config :tymeslot, :allow_payment_event_jobs_in_test, false

# Pricing configuration for tests
config :tymeslot, :pricing,
  pro_monthly_cents: 500,
  pro_annual_cents: 5000

# Skip webhook signature verification in tests
config :tymeslot, :skip_webhook_verification, true

# Health check timeouts for faster testing
config :tymeslot, Tymeslot.Integrations.HealthCheck,
  yield_timeout: 100,
  stream_timeout: 200

# Wallaby E2E browser test configuration
# otp_app + ecto_repos let Wallaby.Feature auto-checkout the sandbox and pass
# the token in request headers so Phoenix.Ecto.SQL.Sandbox can allow the browser
# request process to share the test's DB connection.
# base_url is set dynamically in test_helper.exs via TymeslotWeb.Endpoint.url/0
# so it respects the TEST_PORT env var.
config :wallaby,
  otp_app: :tymeslot,
  ecto_repos: [Tymeslot.Repo],
  driver: Wallaby.Chrome,
  chromedriver: [
    headless: true,
    binary: "/snap/chromium/current/usr/lib/chromium-browser/chrome"
  ]
