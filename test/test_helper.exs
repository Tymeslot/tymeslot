# Configure Swoosh for testing
Application.put_env(:swoosh, :api_client, false)
Application.put_env(:tymeslot, Tymeslot.Mailer, adapter: Swoosh.Adapters.Test)

# Enable test mode to skip sleep calls in workers
Application.put_env(:tymeslot, :test_mode, true)

# Run migrations before tests
Mix.Task.run("ecto.create", ["--quiet"])
Mix.Task.run("ecto.migrate", ["--quiet"])

# Start PubSub for testing
{:ok, _result} =
  Phoenix.PubSub.Supervisor.start_link(name: Tymeslot.TestPubSub, adapter: Phoenix.PubSub.PG2)

# E2E tests require the HTTP server to be running so the browser can connect.
# Enable it before starting the app so the endpoint boots with server: true.
if System.get_env("E2E") == "true" do
  existing_endpoint_config = Application.get_env(:tymeslot, TymeslotWeb.Endpoint, [])

  Application.put_env(
    :tymeslot,
    TymeslotWeb.Endpoint,
    Keyword.put(existing_endpoint_config, :server, true)
  )
end

# Start Ecto sandbox - ensure Repo is ready first
{:ok, _result} = Application.ensure_all_started(:tymeslot)
Ecto.Adapters.SQL.Sandbox.mode(Tymeslot.Repo, :manual)

# Define mocks
Mox.defmock(Tymeslot.CalendarMock,
  for: Tymeslot.Integrations.Calendar.CalendarBehaviour
)

Mox.defmock(Tymeslot.MiroTalkAPIMock,
  for: Tymeslot.Integrations.Video.MiroTalk.MiroTalkClientBehaviour
)

Mox.defmock(Tymeslot.RadicaleClientMock,
  for: Tymeslot.Integrations.Calendar.CalDAV.ClientBehaviour
)

Mox.defmock(Tymeslot.EmailServiceMock, for: Tymeslot.Emails.EmailServiceBehaviour)
Mox.defmock(Tymeslot.HTTPClientMock, for: Tymeslot.Infrastructure.HTTPClientBehaviour)

Mox.defmock(Tymeslot.GoogleOAuthHelperMock,
  for: Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour
)

Mox.defmock(Tymeslot.OutlookOAuthHelperMock,
  for: Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour
)

Mox.defmock(Tymeslot.TeamsOAuthHelperMock,
  for: Tymeslot.Integrations.Video.Teams.TeamsOAuthHelperBehaviour
)

Mox.defmock(GoogleCalendarAPIMock,
  for: Tymeslot.Integrations.Calendar.Google.CalendarAPIBehaviour
)

Mox.defmock(OutlookCalendarAPIMock,
  for: Tymeslot.Integrations.Calendar.Outlook.CalendarAPIBehaviour
)

Mox.defmock(Tymeslot.Payments.StripeMock,
  for: Tymeslot.Payments.Behaviours.StripeProvider
)

Mox.defmock(Tymeslot.Payments.SubscriptionManagerMock,
  for: Tymeslot.Payments.Behaviours.SubscriptionManager
)

Mox.defmock(Tymeslot.Auth.OAuth.ClientMock,
  for: Tymeslot.Auth.OAuth.ClientBehaviour
)

Mox.defmock(Tymeslot.Auth.OAuth.HelperMock,
  for: Tymeslot.Auth.OAuth.HelperBehaviour
)

Mox.defmock(Tymeslot.Auth.SessionMock,
  for: Tymeslot.Infrastructure.SessionBehaviour
)

Mox.defmock(Tymeslot.Media.TranscoderMock, for: Tymeslot.Media.TranscoderBehaviour)

Mox.defmock(Tymeslot.Integrations.HealthCheckMock,
  for: Tymeslot.Integrations.HealthCheck.HealthCheckBehaviour
)

Mox.defmock(Tymeslot.Auth.VerificationMock,
  for: Tymeslot.Infrastructure.VerificationBehaviour
)

# Stripe internal mocks for testing the wrapper
# We use the behaviours defined in Tymeslot.TestMocks
alias Tymeslot.TestMocks.{
  StripeChargeBehaviour,
  StripeCustomerBehaviour,
  StripeSessionBehaviour,
  StripeSubscriptionBehaviour,
  StripeWebhookBehaviour
}

Mox.defmock(StripeCustomerMock, for: StripeCustomerBehaviour)
Mox.defmock(StripeSessionMock, for: StripeSessionBehaviour)
Mox.defmock(StripeSubscriptionMock, for: StripeSubscriptionBehaviour)
Mox.defmock(StripeChargeMock, for: StripeChargeBehaviour)
Mox.defmock(StripeWebhookMock, for: StripeWebhookBehaviour)

max_cases =
  case System.get_env("TEST_MAX_CASES") do
    nil ->
      config = Application.get_env(:tymeslot, Tymeslot.Repo, [])
      pool_size = Keyword.get(config, :pool_size, 10)

      # Use at most half the pool size to leave headroom for sandbox overhead,
      # migrations, and multi-repo access patterns. Minimum of 2 for parallelism.
      max(div(pool_size, 2), 2)

    value ->
      case Integer.parse(value) do
        {int, _value} -> int
        :error -> nil
      end
  end

ExUnit.start()

# Exclude slow/external test suites by default — run them explicitly with --include.
exunit_config = [
  exclude: [
    backup_tests: true,
    oauth_integration: true,
    calendar_integration: true,
    e2e: true,
    migrations: true
  ]
]

exunit_config =
  if max_cases do
    Keyword.put(exunit_config, :max_cases, max_cases)
  else
    exunit_config
  end

ExUnit.configure(exunit_config)

# Start Wallaby for E2E browser tests
if System.get_env("E2E") == "true" do
  Application.put_env(:wallaby, :base_url, TymeslotWeb.Endpoint.url())
  {:ok, _apps} = Application.ensure_all_started(:wallaby)
end
