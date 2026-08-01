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

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Connection
  alias Tymeslot.Integrations.HealthCheck.Assessor
  alias Tymeslot.Security.RateLimiter

  # The bucket allows 20 connection tests per 10 minutes per scope.
  @limit 20

  setup do
    # These fixtures point at localhost — allow the SSRF guard to pass so
    # `validate_config/1` (which now always runs ahead of the probe) doesn't
    # reject them before the rate-limiter logic under test even runs.
    with_config(:tymeslot, :allow_private_ips_for_calendar, true)
    :ok
  end

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
    test "background probing is unmetered by construction and never starves the owner's interactive check" do
      integration = caldav_integration()

      # The scheduler already owns its own cadence (a 30-minute floor plus
      # its own backoff), so `ConnectionProbe` treats `scope: :background` as
      # unmetered by construction — running well past the interactive
      # per-actor limit never trips a refusal, and never draws from the
      # interactive bucket either.
      Enum.each(1..(@limit * 2), fn _i ->
        refute rate_limited?(Assessor.test_integration(:calendar, integration))
      end)

      refute rate_limited?(Connection.test_connection(integration))
    end
  end

  describe "integration creation" do
    # `Calendar.Creation.test_config/3` validates structurally before ever
    # calling `Connection.probe/3` (see its moduledoc), so a structurally
    # invalid submission never draws from the bucket.
    test "a structurally invalid config is rejected without ever touching the rate limiter" do
      user = insert(:user)

      attrs = %{
        "name" => "Bad CalDAV",
        "provider" => "caldav",
        "url" => "not-a-valid-url",
        "username" => "user",
        "password" => "pass",
        "calendar_paths" => ""
      }

      for _i <- 1..(@limit + 5) do
        assert {:error, _reason} = Calendar.create_integration(attrs, user.id)
      end

      # The full per-user budget is still available: none of the failed
      # structural checks above drew from it.
      for _i <- 1..@limit do
        assert :ok = RateLimiter.check_connection_test_rate_limit(:caldav, {:user, user.id})
      end

      assert {:error, :rate_limited, _message} =
               RateLimiter.check_connection_test_rate_limit(:caldav, {:user, user.id})
    end
  end

  defp caldav_integration do
    :calendar_integration
    |> insert(user: insert(:user), provider: "caldav", base_url: "http://localhost:1")
    |> CalendarIntegrationSchema.decrypt_credentials()
  end

  defp exhaust(fun), do: Enum.each(1..@limit, fn _i -> fun.() end)

  defp rate_limited?({:error, {:rate_limited, message}}), do: message =~ "reached the limit"
  defp rate_limited?(_result), do: false
end
