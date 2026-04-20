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

  describe "state persistence across GenServer restart" do
    # The breaker GenServer crashing must not reset recovery progress: a
    # recovering external service must still see `:open` / `:half_open`, not a
    # fresh `:closed` budget that hammers it with retries.
    @describetag :persistence

    defp start_under_own_supervisor(breaker_name, config) do
      child = {CircuitBreaker, name: breaker_name, config: config}
      {:ok, sup} = Supervisor.start_link([child], strategy: :one_for_one)
      on_exit(fn -> stop_supervisor(sup) end)
      sup
    end

    defp stop_supervisor(sup) do
      if Process.alive?(sup), do: Supervisor.stop(sup, :normal, 500)
    rescue
      _error -> :ok
    catch
      :exit, _reason -> :ok
    end

    defp kill_breaker_and_wait(breaker_name) do
      pid = GenServer.whereis(breaker_name)
      assert is_pid(pid)

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000

      wait_for_new_pid(breaker_name, pid, 100)
    end

    defp wait_for_new_pid(_breaker_name, _old_pid, 0), do: nil

    defp wait_for_new_pid(breaker_name, old_pid, retries) do
      case GenServer.whereis(breaker_name) do
        new_pid when is_pid(new_pid) and new_pid != old_pid ->
          new_pid

        _not_yet ->
          tag = make_ref()
          Process.send_after(self(), tag, 10)

          receive do
            ^tag -> wait_for_new_pid(breaker_name, old_pid, retries - 1)
          end
      end
    end

    defp clear_persisted(name) do
      :ets.delete(:circuit_breaker_state_table, name)
    end

    defp backdate_past_recovery(breaker_name) do
      :sys.replace_state(breaker_name, fn state ->
        backdated = System.monotonic_time(:millisecond) - state.config.recovery_timeout - 10
        %{state | last_failure_time: backdated}
      end)
    end

    test "breaker tripped to :open stays :open after a crash and restart" do
      breaker_name = via_name("cb_restart_open_#{System.unique_integer([:positive])}")
      on_exit(fn -> clear_persisted(breaker_name) end)

      start_under_own_supervisor(breaker_name, %{
        failure_threshold: 1,
        recovery_timeout: 60_000
      })

      assert {:error, :fail} = CircuitBreaker.call(breaker_name, fn -> {:error, :fail} end)
      assert %{status: :open} = CircuitBreaker.status(breaker_name)

      restarted_pid = kill_breaker_and_wait(breaker_name)
      assert is_pid(restarted_pid)

      # External service must not be hit on the very first call after restart.
      assert %{status: :open} = CircuitBreaker.status(breaker_name)

      assert {:error, :circuit_open} =
               CircuitBreaker.call(breaker_name, fn -> {:ok, :touched} end)
    end

    test "half-open breaker comes back as :half_open after a crash" do
      breaker_name = via_name("cb_restart_half_#{System.unique_integer([:positive])}")
      on_exit(fn -> clear_persisted(breaker_name) end)

      start_under_own_supervisor(breaker_name, %{
        failure_threshold: 1,
        recovery_timeout: @time_window_ms,
        half_open_requests: 3
      })

      # Trip to open.
      CircuitBreaker.call(breaker_name, fn -> {:error, :fail} end)
      assert %{status: :open} = CircuitBreaker.status(breaker_name)

      # Backdate last_failure_time past the recovery timeout so the next call
      # transitions to :half_open without waiting real time.
      backdate_past_recovery(breaker_name)
      assert {:ok, :recovering} = CircuitBreaker.call(breaker_name, fn -> {:ok, :recovering} end)
      assert %{status: :half_open} = CircuitBreaker.status(breaker_name)

      restarted_pid = kill_breaker_and_wait(breaker_name)
      assert is_pid(restarted_pid)

      # Must remain :half_open — not snap back to :closed with a zero-failure budget.
      assert %{status: :half_open, failure_count: failure_count} =
               CircuitBreaker.status(breaker_name)

      # Failure count from the previous run is preserved.
      assert failure_count >= 1
    end

    test "reset/1 persists :closed so a crash-restart comes back :closed, not :open" do
      breaker_name = via_name("cb_restart_reset_#{System.unique_integer([:positive])}")
      on_exit(fn -> clear_persisted(breaker_name) end)

      start_under_own_supervisor(breaker_name, %{
        failure_threshold: 1,
        recovery_timeout: 60_000
      })

      # Trip to :open.
      CircuitBreaker.call(breaker_name, fn -> {:error, :fail} end)
      assert %{status: :open} = CircuitBreaker.status(breaker_name)

      # Reset to :closed — this must also update the ETS snapshot.
      CircuitBreaker.reset(breaker_name)

      # status/1 is a call, so it linearizes after the preceding cast; no sleep needed.
      assert %{status: :closed} = CircuitBreaker.status(breaker_name)

      restarted_pid = kill_breaker_and_wait(breaker_name)
      assert is_pid(restarted_pid)

      # The persisted snapshot must reflect the reset, not the earlier :open state.
      assert %{status: :closed, failure_count: 0} = CircuitBreaker.status(breaker_name)
    end
  end
end
