defmodule Tymeslot.Integrations.Video.Providers.ProviderAdapterCircuitBreakerTest do
  @moduledoc """
  The video breaker is supervised and configured per provider, but for a long
  time nothing called it: its gauge could only ever read `:closed`. These tests
  pin the wiring itself, at the adapter every provider call goes through.

  Not async: the breakers are application-wide singletons, so opening one has
  to happen with nothing else running against it.
  """

  use ExUnit.Case, async: false

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.CircuitBreaker
  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Integrations.Video.Providers.ProviderAdapter

  # Zoom is the provider that implements both optional room callbacks, so it
  # exercises the adapter paths that reach a provider API without needing a
  # room to exist first.
  @provider :zoom
  @breaker :video_breaker_zoom

  setup do
    # `reset/1` is a cast, so it has to be flushed before the next test starts:
    # a following test that reads this breaker would otherwise see the state
    # this one left behind. `status/1` is a call, so it linearises after it.
    on_exit(fn ->
      CircuitBreaker.reset(@breaker)
      assert %{status: :closed, failure_count: 0} = CircuitBreaker.status(@breaker)
    end)

    :ok
  end

  test "the provider is configured for circuit breaking at all" do
    assert ProviderConfig.circuit_breaker_enabled?(@provider),
           "this test is meaningless if #{@provider} has no breaker configured"
  end

  test "an open circuit refuses a room update before it reaches the provider" do
    open_circuit()

    assert %{status: :open} = CircuitBreaker.status(@breaker)

    assert {:error, :circuit_open} =
             ProviderAdapter.update_meeting_room(@provider, "room-1", %{})
  end

  test "an open circuit refuses a room deletion before it reaches the provider" do
    open_circuit()

    assert {:error, :circuit_open} =
             ProviderAdapter.delete_meeting_room(@provider, "room-1", %{})
  end

  defp open_circuit do
    %{config: %{failure_threshold: threshold}} = CircuitBreaker.status(@breaker)

    for _attempt <- 1..threshold do
      CircuitBreaker.call(@breaker, fn -> {:error, :induced} end,
        classify: fn _result -> :failure end
      )
    end
  end
end
