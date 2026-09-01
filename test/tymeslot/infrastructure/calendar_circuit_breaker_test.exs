defmodule Tymeslot.Infrastructure.CalendarCircuitBreakerTest do
  # Host breakers are dynamically registered, global processes shared with
  # every other test; async: false keeps a concurrently running module from
  # tripping (or resetting) the one this test creates.
  use ExUnit.Case, async: false

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Infrastructure.CircuitBreaker

  describe "reset_all_hosts/0" do
    test "clears the persisted ETS snapshot for a tripped host breaker, not just its live state" do
      host = "reset-all-hosts-#{System.unique_integer([:positive])}.example.com"
      failure_threshold = CalendarCircuitBreaker.get_config(:google).failure_threshold

      for _i <- 1..failure_threshold do
        CalendarCircuitBreaker.call_with_host(:google, host, fn -> {:provider_error, :fail} end)
      end

      safe_host = String.replace(host, ~r/[^a-zA-Z0-9]/, "_")
      breaker_id = "calendar_breaker_google_#{safe_host}"

      breaker_name =
        {:via, Registry, {Tymeslot.Infrastructure.CircuitBreakerRegistry, breaker_id}}

      # `record_outcome` is reported via `GenServer.cast`, so the breaker
      # processes it after this test's calls above have already returned.
      # A synchronous call to the same process is queued behind those casts
      # in its mailbox, so waiting on its reply guarantees every prior cast
      # (including the ETS write for the final failure) has been applied.
      CircuitBreaker.status(breaker_name)

      # Sanity check: the host breaker actually tripped and persisted :open.
      assert [{^breaker_name, %{status: :open}}] =
               :ets.lookup(:circuit_breaker_state_table, breaker_name)

      CalendarCircuitBreaker.reset_all_hosts()

      # `reset/1` deletes the ETS row synchronously and then re-persists a
      # `:closed` snapshot via an async cast; wait on the same process again
      # so that cast (and its `persist_state`) is guaranteed to have run.
      CircuitBreaker.status(breaker_name)

      # `reset/1`'s ETS clear must resolve the pid back to its registered
      # name — a pid-addressed delete is a no-op, and the stale :open
      # snapshot would otherwise resurrect on the breaker's next restart.
      assert [{^breaker_name, %{status: :closed}}] =
               :ets.lookup(:circuit_breaker_state_table, breaker_name)
    end
  end
end
