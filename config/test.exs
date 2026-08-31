import Config

# Configure environment
config :tymeslot, environment: :test, test_mode: true

# Reduce bcrypt cost for tests — default log_rounds (12) adds ~200-400ms per
# password hash, which compounds across hundreds of factory user inserts.
config :bcrypt_elixir, log_rounds: 4

# Core tests must not enforce legal agreements.
config :tymeslot, enforce_legal_agreements: false

# Force Core to use Tymeslot.PubSub in tests
config :tymeslot, :force_app_pubsub_in_test, true
config :tymeslot, :pubsub_name, Tymeslot.PubSub

# Force core router for tests
config :tymeslot, :router, TymeslotWeb.Router

# Upload directory for tests: a per-partition temp dir, cleaned up after the
# suite (see test_helper.exs). Keeps generated avatars/attachments out of the
# repo tree entirely.
config :tymeslot,
       :upload_directory,
       Path.join(
         System.tmp_dir!(),
         "tymeslot_test_uploads#{System.get_env("MIX_TEST_PARTITION")}"
       )

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

# Data-at-rest encryption key, decoupled from SECRET_KEY_BASE. A fixed default is
# used in test; production supplies DATA_ENCRYPTION_KEY via runtime.exs.
config :tymeslot, Tymeslot.Security.Encryption,
  data_encryption_key:
    System.get_env("DATA_ENCRYPTION_KEY") ||
      "RsxoYoIVSu/K+QDV2yukDwTFD3wDyDSFxuGmoauNAX0FcXJF58dAz5LhEyiNqhFP"

# Configure the database.
# An async test holds exactly one sandbox connection for its whole lifetime
# (see Tymeslot.DataCase.setup_sandbox/1), so the pool is the hard ceiling on
# suite parallelism: `max_cases` can never usefully exceed it. Sizing it one
# per scheduler plus a small margin lets Tymeslot.Test.SuiteConfig derive a
# `max_cases` that actually fills the machine, while the floor keeps small
# hosts at the previous fixed value rather than below it. TEST_DB_POOL_SIZE
# overrides it.
default_pool_size = max(System.schedulers_online() + 4, 10)

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
  pruner: [max_age: {1, :hour}],
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
config :tymeslot, :verification_module, Tymeslot.Auth.VerificationMock
config :tymeslot, :oauth_callback_module, Tymeslot.Auth.OAuth.HelperMock

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

# Write page views inline rather than in a fire-and-forget Task, so the write is
# owned by the test process. A supervised Task outlives the test that mounted the
# LiveView, and hits a torn-down sandbox connection with a
# `DBConnection.OwnershipError` that ExUnit reports but does not fail on.
config :tymeslot, :async_page_view_logging, false

# Resolve month availability inline rather than in a linked Task, so the result
# is owned by the test process. Both modes deliver the same `{ref, result}`
# message to the same handler at the same point in the LiveView lifecycle; what
# the inline mode removes is a task still in flight when a test ends, which is
# killed mid-query and takes the checked-out sandbox connection with it.
# `TymeslotWeb.Live.Scheduling.AvailabilityAsyncFetchTest` flips this back on to
# cover the task path itself.
config :tymeslot, :async_availability_fetch, false

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
  apple: [enabled: true],
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

# Payment retries sleep between attempts, and the suite was sleeping the
# production 1s base delay: ten tests across RetryHelperTest and StripeTest
# waiting out real backoff for about 18 seconds of every run. Only the delay is
# shortened; max_attempts and backoff_multiplier keep their production values,
# so the attempt-count and backoff-shape assertions still test what they say.
config :tymeslot, :payment_retry, base_delay_ms: 1

# Wallaby E2E browser test configuration
# otp_app + ecto_repos let Wallaby.Feature auto-checkout the sandbox and pass
# the token in request headers so Phoenix.Ecto.SQL.Sandbox can allow the browser
# request process to share the test's DB connection.
# base_url is set dynamically in test_helper.exs via TymeslotWeb.Endpoint.url/0
# so it respects the TEST_PORT env var.
# Failure screenshots go to the system temp directory, not into the checkout:
# they are disposable artefacts of a failed run, and writing them under test/
# left untracked PNGs behind after every red e2e run. Wallaby mkdir_p's the
# directory itself, so nothing has to create it.
config :wallaby,
  otp_app: :tymeslot,
  ecto_repos: [Tymeslot.Repo],
  driver: Wallaby.Chrome,
  screenshot_on_failure: true,
  screenshot_dir: Path.join(System.tmp_dir!(), "tymeslot-screenshots"),
  chromedriver: [
    headless: true,
    binary: "/snap/chromium/current/usr/lib/chromium-browser/chrome"
  ]
