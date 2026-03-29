defmodule Tymeslot.Infrastructure.CircuitBreakerTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.CircuitBreaker

  @registry Tymeslot.Infrastructure.CircuitBreakerRegistry

  # Use a generous window/sleep ratio (4×) to avoid timing-sensitive flakes in CI.
  @time_window_ms 50
  @sleep_ms 200

  defp via_name(key \\ nil) do
    key = key || "cb_test_#{System.unique_integer([:positive])}"
    {:via, Registry, {@registry, key}}
  end

  defp start_breaker(opts \\ []) do
    name = Keyword.get(opts, :name, via_name())
    config = Keyword.get(opts, :config, %{})

    start_supervised!({CircuitBreaker, name: name, config: config})

    name
  end

  describe "closed state" do
    test "successful calls return {:ok, result}" do
      name = start_breaker()

      assert {:ok, 42} = CircuitBreaker.call(name, fn -> {:ok, 42} end)
    end

    test "successful calls increment success_count" do
      name = start_breaker()

      CircuitBreaker.call(name, fn -> {:ok, :a} end)
      CircuitBreaker.call(name, fn -> {:ok, :b} end)

      assert %{success_count: 2, failure_count: 0, status: :closed} =
               CircuitBreaker.status(name)
    end

    test "failed calls increment failure_count" do
      name = start_breaker(config: %{failure_threshold: 10})

      CircuitBreaker.call(name, fn -> {:error, :boom} end)
      CircuitBreaker.call(name, fn -> {:error, :boom} end)

      assert %{failure_count: 2, status: :closed} = CircuitBreaker.status(name)
    end

    test "non-tagged-tuple returns are wrapped in {:ok, result}" do
      name = start_breaker()

      assert {:ok, :raw_value} = CircuitBreaker.call(name, fn -> :raw_value end)
      assert {:ok, "string"} = CircuitBreaker.call(name, fn -> "string" end)
    end

    test "exceptions are caught and counted as failures" do
      name = start_breaker(config: %{failure_threshold: 10})

      assert {:error, %RuntimeError{}} =
               CircuitBreaker.call(name, fn -> raise "boom" end)

      assert %{failure_count: 1} = CircuitBreaker.status(name)
    end
  end

  describe "closed -> open transition" do
    test "opens after failure_threshold failures within time window" do
      name = start_breaker(config: %{failure_threshold: 3, time_window: 60_000})

      CircuitBreaker.call(name, fn -> {:error, :fail} end)
      CircuitBreaker.call(name, fn -> {:error, :fail} end)

      assert %{status: :closed} = CircuitBreaker.status(name)

      CircuitBreaker.call(name, fn -> {:error, :fail} end)

      assert %{status: :open} = CircuitBreaker.status(name)
    end

    test "failures outside time window don't count toward threshold" do
      name =
        start_breaker(config: %{failure_threshold: 3, time_window: @time_window_ms})

      CircuitBreaker.call(name, fn -> {:error, :fail} end)
      CircuitBreaker.call(name, fn -> {:error, :fail} end)

      # Wait well past the window before the third failure
      Process.sleep(@sleep_ms)

      CircuitBreaker.call(name, fn -> {:error, :fail} end)

      # Should still be closed because window reset cleared earlier failures
      assert %{status: :closed} = CircuitBreaker.status(name)
    end
  end

  describe "open state" do
    test "calls immediately return {:error, :circuit_open}" do
      name = start_breaker(config: %{failure_threshold: 1, recovery_timeout: 60_000})

      CircuitBreaker.call(name, fn -> {:error, :fail} end)

      assert %{status: :open} = CircuitBreaker.status(name)
      assert {:error, :circuit_open} = CircuitBreaker.call(name, fn -> {:ok, :ignored} end)
    end
  end

  describe "open -> half-open transition" do
    test "transitions to half-open after recovery_timeout" do
      name =
        start_breaker(
          config: %{
            failure_threshold: 1,
            recovery_timeout: @time_window_ms,
            half_open_requests: 1
          }
        )

      CircuitBreaker.call(name, fn -> {:error, :fail} end)
      assert %{status: :open} = CircuitBreaker.status(name)

      # Wait well past the recovery timeout
      Process.sleep(@sleep_ms)

      # Next call should go through (half-open)
      assert {:ok, :recovered} = CircuitBreaker.call(name, fn -> {:ok, :recovered} end)
      assert %{status: :closed} = CircuitBreaker.status(name)
    end
  end

  describe "half-open state" do
    test "success closes the circuit after half_open_requests successful calls" do
      name =
        start_breaker(
          config: %{
            failure_threshold: 1,
            recovery_timeout: @time_window_ms,
            half_open_requests: 2
          }
        )

      # Open the breaker
      CircuitBreaker.call(name, fn -> {:error, :fail} end)
      assert %{status: :open} = CircuitBreaker.status(name)

      Process.sleep(@sleep_ms)

      # First half-open success
      assert {:ok, :ok1} = CircuitBreaker.call(name, fn -> {:ok, :ok1} end)

      # Second half-open success should close
      assert {:ok, :ok2} = CircuitBreaker.call(name, fn -> {:ok, :ok2} end)
      assert %{status: :closed} = CircuitBreaker.status(name)
    end

    test "failure in half-open immediately reopens the circuit" do
      name =
        start_breaker(
          config: %{
            failure_threshold: 1,
            recovery_timeout: @time_window_ms,
            half_open_requests: 3
          }
        )

      CircuitBreaker.call(name, fn -> {:error, :fail} end)
      assert %{status: :open} = CircuitBreaker.status(name)

      Process.sleep(@sleep_ms)

      # Fail in half-open
      assert {:error, :fail_again} =
               CircuitBreaker.call(name, fn -> {:error, :fail_again} end)

      assert %{status: :open} = CircuitBreaker.status(name)
    end

    test "closes circuit after all half_open_requests succeed" do
      name =
        start_breaker(
          config: %{
            failure_threshold: 1,
            recovery_timeout: @time_window_ms,
            half_open_requests: 2
          }
        )

      CircuitBreaker.call(name, fn -> {:error, :fail} end)
      Process.sleep(@sleep_ms)

      # First call in half-open succeeds (attempts: 1)
      assert {:ok, :ok1} = CircuitBreaker.call(name, fn -> {:ok, :ok1} end)

      # Second call succeeds => attempts == half_open_requests => closes
      assert {:ok, :ok2} = CircuitBreaker.call(name, fn -> {:ok, :ok2} end)
      assert %{status: :closed} = CircuitBreaker.status(name)
    end
  end

  describe "reset/1" do
    test "resets circuit to closed state" do
      name = start_breaker(config: %{failure_threshold: 1, recovery_timeout: 60_000})

      CircuitBreaker.call(name, fn -> {:error, :fail} end)
      assert %{status: :open} = CircuitBreaker.status(name)

      CircuitBreaker.reset(name)

      # status/1 is a call, so it linearizes after the preceding cast; no sleep needed
      assert %{status: :closed, failure_count: 0, success_count: 0} =
               CircuitBreaker.status(name)
    end
  end

  describe "status/1" do
    test "returns correct state map" do
      name = start_breaker()

      status = CircuitBreaker.status(name)

      assert %{status: :closed, failure_count: 0, success_count: 0, config: config} = status
      assert is_map(config)
      assert Map.has_key?(config, :failure_threshold)
    end
  end

  describe "custom config" do
    test "merges user config with defaults" do
      name = start_breaker(config: %{failure_threshold: 10})

      %{config: config} = CircuitBreaker.status(name)

      assert config.failure_threshold == 10
      # Defaults should still be present
      assert config.recovery_timeout == :timer.minutes(5)
      assert config.half_open_requests == 3
    end
  end
end
