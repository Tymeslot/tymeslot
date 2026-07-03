# Configure Swoosh for testing
Application.put_env(:swoosh, :api_client, false)
Application.put_env(:tymeslot, Tymeslot.Mailer, adapter: Swoosh.Adapters.Test)

# Enable test mode to skip sleep calls in workers
Application.put_env(:tymeslot, :test_mode, true)

# Run migrations before tests
Mix.Task.run("ecto.create", ["--quiet"])
Mix.Task.run("ecto.migrate", ["--quiet"])

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

# Mox mocks are defined once, at compile time, in
# apps/tymeslot/test/support/mocks/defmocks.ex (shared across the umbrella).

# Analytics: collect emitted events across the suite; assert completeness only
# under ANALYTICS_COMPLETENESS=1 (see Tymeslot.Test.SuiteConfig).
Tymeslot.Test.SuiteConfig.setup_analytics_completeness(
  Tymeslot.Analytics.TestCollector,
  Tymeslot.Analytics.Contract
)

Tymeslot.Test.SuiteConfig.cleanup_uploads_after_suite()

ExUnit.start()

base_config = [capture_log: true, exclude: Tymeslot.Test.SuiteConfig.default_exclude_tags()]

exunit_config =
  case Tymeslot.Test.SuiteConfig.max_cases() do
    nil -> base_config
    max_cases -> Keyword.put(base_config, :max_cases, max_cases)
  end

ExUnit.configure(exunit_config)

# Start Wallaby for E2E browser tests
if System.get_env("E2E") == "true" do
  Application.put_env(:wallaby, :base_url, TymeslotWeb.Endpoint.url())
  {:ok, _apps} = Application.ensure_all_started(:wallaby)
end
