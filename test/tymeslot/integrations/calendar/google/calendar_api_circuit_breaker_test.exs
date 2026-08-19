defmodule Tymeslot.Integrations.Calendar.Google.CalendarAPICircuitBreakerTest do
  # async: false is required: the calendar circuit breakers are global, and
  # nothing scopes one to a test. `DataCase.reset_stateful_components/1` clears
  # them in every sync test's setup, which is safe only because sync modules run
  # alone; under async: true a sibling module's tests would still be running
  # against the breaker this one trips.
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI
  alias Tymeslot.Security.Encryption

  describe "bootstrap_sync/1 circuit breaker integration" do
    test "propagates {:error, :circuit_open} when circuit breaker is open" do
      CalendarCircuitBreaker.reset(:google)
      on_exit(fn -> CalendarCircuitBreaker.reset(:google) end)

      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
        )

      # Trip the Google circuit breaker (threshold is 5).
      Enum.each(1..5, fn _i ->
        CalendarCircuitBreaker.call(:google, fn -> {:provider_error, :api_failure} end)
      end)

      assert %{status: :open} = CalendarCircuitBreaker.status(:google)
      assert {:error, :circuit_open} = CalendarAPI.bootstrap_sync(integration)
    end
  end
end
