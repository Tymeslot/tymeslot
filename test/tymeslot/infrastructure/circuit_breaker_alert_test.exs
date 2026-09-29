defmodule Tymeslot.Infrastructure.CircuitBreakerAlertTest do
  # async: false: the admin alert implementation is global application env,
  # and the telemetry handler under test is attached globally.
  use ExUnit.Case, async: false

  @moduletag :infrastructure

  import Tymeslot.AdminAlertsCaptureHelpers

  alias Tymeslot.Infrastructure.AdminAlerts.AlertTypes
  alias Tymeslot.Infrastructure.CircuitBreaker
  alias Tymeslot.Infrastructure.Metrics

  setup :capture_admin_alerts

  setup do
    # Another test module detaches the application's handlers when it
    # finishes, so attach them here rather than rely on boot having done so.
    Metrics.setup_handlers()
    :ok
  end

  defp start_breaker(name) do
    start_supervised!(
      {CircuitBreaker,
       name: name, config: %{failure_threshold: 2, recovery_timeout: 0, half_open_requests: 1}}
    )

    name
  end

  defp fail(name, reason \\ :timeout),
    do: CircuitBreaker.call(name, fn -> {:error, reason} end)

  test "opening a breaker raises one alert naming it, its failure count and last error" do
    name = start_breaker(:alert_test_breaker)

    fail(name, :econnrefused)
    refute_receive {:send_alert, :circuit_breaker_open, _payload}, 50

    fail(name, {:http_error, 503, "Service Unavailable, key=sk_live_secret"})

    assert_receive {:send_alert, :circuit_breaker_open, payload}
    assert payload.breaker == "alert_test_breaker"
    assert payload.old_state == :closed
    assert payload.failure_count == 2
    assert payload.last_error == "HTTP 503"
    refute inspect(payload) =~ "sk_live_secret"

    assert AlertTypes.format_message(:circuit_breaker_open, payload) =~ "alert_test_breaker"
    refute_receive {:send_alert, :circuit_breaker_open, _payload}, 50
  end

  test "reopening the breaker within the hour raises an alert that deduplicates with the first" do
    name = start_breaker(:alert_reopen_breaker)

    fail(name)
    fail(name)
    assert_receive {:send_alert, :circuit_breaker_open, first}

    # recovery_timeout 0: the next call is a half-open probe; its failure
    # reopens the circuit.
    fail(name)
    assert_receive {:send_alert, :circuit_breaker_open, second}

    assert second.old_state == :half_open

    assert AlertTypes.dedup_key(:circuit_breaker_open, first) ==
             AlertTypes.dedup_key(:circuit_breaker_open, second)
  end

  test "a breaker closing or going half-open raises no alert" do
    name = start_breaker(:alert_close_breaker)

    fail(name)
    fail(name)
    assert_receive {:send_alert, :circuit_breaker_open, _payload}

    assert {:ok, :fine} = CircuitBreaker.call(name, fn -> {:ok, :fine} end)
    assert %{status: :closed} = CircuitBreaker.status(name)
    refute_receive {:send_alert, _type, _payload}, 100
  end
end
