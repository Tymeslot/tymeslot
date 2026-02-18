defmodule Tymeslot.Infrastructure.CacheStoreTest do
  @moduledoc """
  Tests for CacheStore module with request coalescing and TTL.

  ## Note on Process.sleep Usage

  This file uses `Process.sleep/1` intentionally to test cache behavior:

  1. Simulate slow computations to verify request coalescing works - multiple
     concurrent requests should share the same computation
  2. Create timing windows to test race conditions in cache population
  3. Verify that crash recovery works correctly when computations fail

  These sleeps are necessary to test the cache's concurrency control mechanism.
  """

  use ExUnit.Case, async: false

  @moduletag :infrastructure

  import Tymeslot.TestHelpers.Eventually

  defmodule TestCache do
    use Tymeslot.Infrastructure.CacheStore,
      table_name: :test_cache,
      default_ttl: :timer.seconds(1),
      cleanup_interval: :timer.seconds(5)
  end

  setup do
    start_supervised!(TestCache)
    TestCache.clear_all()
    :ok
  end

  test "get_or_compute caches the value" do
    key = "key1"
    counter = :erlang.unique_integer()

    # First call computes
    val1 = TestCache.get_or_compute(key, fn -> {:computed, counter} end)

    # Second call returns cached
    val2 = TestCache.get_or_compute(key, fn -> {:computed, :erlang.unique_integer()} end)

    assert val1 == val2
    assert val1 == {:computed, counter}
  end

  test "get_or_compute coalesces concurrent requests (prevents stampede)" do
    # Force coalescing even in test environment for this specific test
    Application.put_env(:tymeslot, :force_cache_coalescing, true)
    on_exit(fn -> Application.delete_env(:tymeslot, :force_cache_coalescing) end)

    key = "stampede_key"
    parent = self()

    # Start 5 concurrent requests
    tasks =
      Enum.map(1..5, fn _task_index ->
        Task.async(fn ->
          TestCache.get_or_compute(key, fn ->
            # Signal that we started computing
            send(parent, :computing_started)
            # Simulate slow computation
            Process.sleep(100)
            :result
          end)
        end)
      end)

    results = Task.yield_many(tasks, 500)

    # Verify all got the same result
    Enum.each(results, fn {_task, {:ok, res}} ->
      assert res == :result
    end)

    # Verify the computation function was only called ONCE
    # We should have exactly one :computing_started message in our mailbox
    messages = collect_messages([])
    assert length(Enum.filter(messages, &(&1 == :computing_started))) == 1
  end

  test "invalidate removes item from cache" do
    TestCache.get_or_compute("key", fn -> "val" end)
    assert TestCache.get_or_compute("key", fn -> "new" end) == "val"

    TestCache.invalidate("key")
    assert TestCache.get_or_compute("key", fn -> "new" end) == "new"
  end

  test "get_or_compute handles task crashes gracefully" do
    # Force coalescing even in test environment for this specific test
    Application.put_env(:tymeslot, :force_cache_coalescing, true)
    on_exit(fn -> Application.delete_env(:tymeslot, :force_cache_coalescing) end)

    key = "crash_key"

    # Start a request that will crash
    task1 =
      Task.async(fn ->
        TestCache.get_or_compute(key, fn ->
          Process.sleep(50)
          raise "Computation crashed!"
        end)
      end)

    # Start another request that will wait for the first one
    task2 =
      Task.async(fn ->
        Process.sleep(20)

        TestCache.get_or_compute(key, fn ->
          :this_should_not_be_called_yet
        end)
      end)

    # Both should get the error result instead of timing out or hanging
    eventually(fn ->
      assert Task.await(task1) == {:error, :computation_failed}
      assert Task.await(task2) == {:error, :computation_failed}
    end)

    # Verify that we can try again and succeed
    assert TestCache.get_or_compute(key, fn -> :success end) == :success
  end

  defp collect_messages(acc) do
    receive do
      msg -> collect_messages([msg | acc])
    after
      0 -> acc
    end
  end
end
