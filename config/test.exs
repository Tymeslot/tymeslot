import Config

# Configure environment
config :tymeslot, environment: :test

# Configure upload directory for tests
config :tymeslot, :upload_directory, Path.expand("test/uploads")

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :tymeslot, TymeslotWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("TEST_PORT") || "4002")],
  url: [host: "localhost", port: String.to_integer(System.get_env("TEST_PORT") || "4002"), scheme: "http"],
  secret_key_base:
    System.get_env("SECRET_KEY_BASE") ||
      "j47WN/+e1mzK5Volysi74F0YKzItGcdYUBq3T5QjmnZDcAnsAJE28y5XCysI66kP",
  live_view: [signing_salt: System.get_env("LIVE_VIEW_SIGNING_SALT") || "TESTlVs1gn1ngS4lt"],
  server: false

# Configure the database
config :tymeslot, Tymeslot.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "tymeslot_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Configure Oban for testing (disable all plugins and queues)
config :tymeslot, Oban,
  repo: Tymeslot.Repo,
  testing: :manual

# In test we don't send emails
config :tymeslot, Tymeslot.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Standardized mock configuration following testing strategy
# "Mock configuration centralized" principle
config :tymeslot, :calendar_module, Tymeslot.CalendarMock
config :tymeslot, :calendar_client_module, Tymeslot.RadicaleClientMock
config :tymeslot, :mirotalk_api_module, Tymeslot.MiroTalkAPIMock
config :tymeslot, :email_service_module, Tymeslot.EmailServiceMock
config :tymeslot, :google_calendar_api_module, GoogleCalendarAPIMock
config :tymeslot, :outlook_calendar_api_module, OutlookCalendarAPIMock
config :tymeslot, :google_calendar_oauth_helper, Tymeslot.GoogleOAuthHelperMock
config :tymeslot, :outlook_calendar_oauth_helper, Tymeslot.OutlookOAuthHelperMock
config :tymeslot, :http_client_module, Tymeslot.HTTPClientMock

# Also support the legacy key for backward compatibility
config :tymeslot, :email_service, Tymeslot.EmailServiceMock

# MiroTalk test configuration
config :tymeslot, :mirotalk_api,
  api_key: "test-api-key",
  base_url: "https://test.mirotalk.com"

# Scheduling settings are now stored in the database (profiles table)
# Tests should create profiles with the desired settings

# Configure email settings for test
from_email = System.get_env("EMAIL_FROM_ADDRESS") || "hello@tymeslot.app"

config :tymeslot, :email,
  from_name: System.get_env("EMAIL_FROM_NAME") || "Tymeslot",
  from_email: from_email,
  support_email: System.get_env("EMAIL_SUPPORT_ADDRESS") || from_email,
  contact_recipient: System.get_env("EMAIL_CONTACT_RECIPIENT") || from_email,
  domain: System.get_env("PHX_HOST") || "tymeslot.app"

# Configure radicale for test (even though we use mocks, the cache worker needs this)
config :tymeslot, :radicale,
  url: "http://localhost:5232",
  username: "test",
  password: "test",
  calendar_path: "/test/calendar.ics/"

# Configure auth for test
config :tymeslot, :auth, success_redirect_path: "/dashboard"
