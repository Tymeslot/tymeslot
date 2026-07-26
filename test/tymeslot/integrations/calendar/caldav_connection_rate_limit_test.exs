defmodule Tymeslot.Integrations.Calendar.CaldavConnectionRateLimitTest do
  @moduledoc """
  The CalDAV connection-test bucket must be partitioned by whoever asked for the
  test — the same defect fixed for MiroTalk.

  It used to be keyed on an `ip_address` that defaulted to `"127.0.0.1"` because
  no server-side caller ever supplied one, so every calendar connection check on
  the whole instance — scheduled health probes and the settings "Test
  connection" button alike — drew from a single bucket of 20 per 10 minutes.
  """

  # Synchronous like the other rate-limiter suites: several async tests call
  # `RateLimiter.clear_all/0`, which wipes the shared ETS table these counts
  # depend on.
  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :security

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Connection
  alias Tymeslot.Integrations.HealthCheck.Assessor

  # The bucket allows 20 connection tests per 10 minutes per scope.
  @limit 20

  describe "interactive connection tests" do
    test "one user hammering the button cannot exhaust another user's budget" do
      noisy = caldav_integration()
      quiet = caldav_integration()

      exhaust(fn -> Connection.test_connection(noisy) end)

      assert rate_limited?(Connection.test_connection(noisy))
      refute rate_limited?(Connection.test_connection(quiet))
    end
  end

  describe "scheduled health probes" do
    test "cannot starve the owner's interactive check" do
      integration = caldav_integration()

      exhaust(fn -> Assessor.test_integration(:calendar, integration) end)

      # The background bucket is real — it just belongs to the integration.
      assert rate_limited?(Assessor.test_integration(:calendar, integration))
      refute rate_limited?(Connection.test_connection(integration))
    end
  end

  defp caldav_integration do
    :calendar_integration
    |> insert(user: insert(:user), provider: "caldav", base_url: "http://localhost:1")
    |> CalendarIntegrationSchema.decrypt_credentials()
  end

  defp exhaust(fun), do: Enum.each(1..@limit, fn _i -> fun.() end)

  defp rate_limited?({:error, message}) when is_binary(message),
    do: message =~ "reached the limit"

  defp rate_limited?(_result), do: false
end
