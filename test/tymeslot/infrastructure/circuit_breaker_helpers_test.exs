defmodule Tymeslot.Infrastructure.CircuitBreakerHelpersTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.CircuitBreaker
  alias Tymeslot.Infrastructure.CircuitBreakerHelpers

  @registry Tymeslot.Infrastructure.CircuitBreakerRegistry

  defp via_name do
    key = "cbh_test_#{System.unique_integer([:positive])}"
    {:via, Registry, {@registry, key}}
  end

  describe "call_with_breaker/4" do
    test "returns {:ok, result} when breaker exists and function succeeds" do
      name = via_name()
      start_supervised!({CircuitBreaker, name: name, config: %{}})

      assert {:ok, 42} =
               CircuitBreakerHelpers.call_with_breaker(name, :test, "Test", fn ->
                 {:ok, 42}
               end)
    end

    test "returns {:error, :circuit_open} when circuit is open" do
      name = via_name()

      start_supervised!(
        {CircuitBreaker, name: name, config: %{failure_threshold: 1, recovery_timeout: 60_000}}
      )

      # Open the circuit
      CircuitBreaker.call(name, fn -> {:provider_error, :fail} end)

      assert {:error, :circuit_open} =
               CircuitBreakerHelpers.call_with_breaker(name, :test, "Test", fn ->
                 {:ok, :should_not_run}
               end)
    end

    test "returns {:error, reason} when function fails" do
      name = via_name()

      start_supervised!({CircuitBreaker, name: name, config: %{failure_threshold: 10}})

      assert {:error, :some_error} =
               CircuitBreakerHelpers.call_with_breaker(name, :test, "Test", fn ->
                 {:error, :some_error}
               end)
    end

    test "returns {:error, :breaker_not_found} when process doesn't exist" do
      key = "nonexistent_#{System.unique_integer([:positive])}"
      fake_name = {:via, Registry, {@registry, key}}

      assert {:error, :breaker_not_found} =
               CircuitBreakerHelpers.call_with_breaker(fake_name, :test, "Test", fn ->
                 {:ok, :ignored}
               end)
    end

    test "returns {:error, :circuit_breaker_error} on unexpected exception" do
      # Use a breaker_name that will cause breaker_exists? to raise
      # by passing something that isn't an atom or via tuple
      assert {:error, :circuit_breaker_error} =
               CircuitBreakerHelpers.call_with_breaker(
                 "not_a_valid_name",
                 :test,
                 "Test",
                 fn -> {:ok, :ignored} end
               )
    end

    test "returns {:error, :circuit_breaker_error} instead of exiting when the breaker dies mid-call" do
      # `GenServer.call/3` signals a dead/crashed target as an *exit*, not a
      # raised exception, so `rescue` alone cannot see it. Simulate that by
      # registering a plain process (not a real breaker) under the via tuple
      # that exits the instant it receives the call.
      key = "cbh_dying_#{System.unique_integer([:positive])}"
      via = {:via, Registry, {@registry, key}}
      test_pid = self()

      spawn(fn ->
        Registry.register(@registry, key, nil)
        send(test_pid, :registered)

        receive do
          {:"$gen_call", _from, _request} -> exit(:simulated_crash)
        end
      end)

      assert_receive :registered

      assert {:error, :circuit_breaker_error} =
               CircuitBreakerHelpers.call_with_breaker(via, :test, "Test", fn ->
                 {:ok, :ignored}
               end)
    end
  end

  describe "breaker_exists?/1" do
    test "returns true for registered atom name" do
      # Start a named breaker locally so this test doesn't depend on app-level startup
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      atom_name = :"cbh_atom_test_#{System.unique_integer([:positive])}"
      start_supervised!({CircuitBreaker, name: atom_name, config: %{}}, id: atom_name)

      assert CircuitBreakerHelpers.breaker_exists?(atom_name) == true
    end

    test "returns false for unregistered atom name" do
      assert CircuitBreakerHelpers.breaker_exists?(:nonexistent_test_breaker) == false
    end

    test "returns true for via-tuple registered in Registry" do
      key = "test_breaker_#{System.unique_integer([:positive])}"
      via = {:via, Registry, {@registry, key}}

      start_supervised!({CircuitBreaker, name: via, config: %{}}, id: key)

      assert CircuitBreakerHelpers.breaker_exists?(via) == true
    end

    test "returns false for via-tuple not registered in Registry" do
      key = "not_registered_#{System.unique_integer([:positive])}"
      via = {:via, Registry, {@registry, key}}

      assert CircuitBreakerHelpers.breaker_exists?(via) == false
    end
  end
end
