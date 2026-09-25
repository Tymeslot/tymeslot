defmodule Tymeslot.Infrastructure.CacheStoreTest do
  @moduledoc """
  Tests for `CacheStore`: TTL storage, and the request coalescing that every
  cache miss now goes through in every environment.

  Concurrency here is synchronised by message, never by sleeping: a
  computation announces itself, parks until the test releases it, and the
  test uses that window to line the other callers up behind it. The one place
  the cache's own state is inspected (`waiters_for/2`) is a barrier, not an
  assertion — it is how the test knows a caller is genuinely blocked as a
  waiter rather than about to arrive late and find a cache hit.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Tymeslot.TestHelpers.Eventually

  alias Tymeslot.Infrastructure.CacheStore

  @moduletag :infrastructure

  defmodule TestCache do
    use Tymeslot.Infrastructure.CacheStore,
      table_name: :test_cache,
      default_ttl: :timer.seconds(5),
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

    val1 = TestCache.get_or_compute(key, fn -> {:computed, counter} end)
    val2 = TestCache.get_or_compute(key, fn -> {:computed, :erlang.unique_integer()} end)

    assert val1 == val2
    assert val1 == {:computed, counter}
  end

  test "invalidate removes item from cache" do
    TestCache.get_or_compute("key", fn -> "val" end)
    assert TestCache.get_or_compute("key", fn -> "new" end) == "val"

    TestCache.invalidate("key")
    assert TestCache.get_or_compute("key", fn -> "new" end) == "new"
  end

  test "the computation runs in the calling process, not in a cache-owned one" do
    caller = self()

    TestCache.get_or_compute("ownership", fn ->
      send(caller, {:computed_in, self()})
      :done
    end)

    assert_received {:computed_in, computing_pid}

    # The property the whole design rests on: a computation that queries the
    # database or meets a Mox expectation keeps the caller's sandbox
    # connection and its allowances, because it never leaves the caller.
    assert computing_pid == caller
  end

  test "concurrent misses on one key compute once and all receive that value" do
    key = "stampede"
    caller = self()

    {leader, leader_pid} = claim_lead(key)

    waiters =
      for _index <- 1..4 do
        Task.async(fn ->
          TestCache.get_or_compute(key, fn ->
            send(caller, :waiter_computed)
            :from_waiter
          end)
        end)
      end

    # All four are parked behind the leader before it is allowed to finish, so
    # this is the coalescing path and not four cache hits.
    await_waiters(key, 4)

    send(leader_pid, {:finish, fn -> :from_leader end})

    assert Task.await(leader) == :from_leader
    assert Enum.map(waiters, &Task.await/1) == List.duplicate(:from_leader, 4)
    refute_received :waiter_computed
  end

  test "the leader stores the value before returning, so the next call is a hit" do
    key = "postcondition"

    assert TestCache.get_or_compute(key, fn -> :first end) == :first
    assert CacheStore.lookup(:test_cache, key) == {:ok, :first}
  end

  test "a raising computation resolves to :computation_failed for leader and waiters" do
    key = "crash"

    log =
      capture_log(fn ->
        {leader, leader_pid} = claim_lead(key)

        waiter = Task.async(fn -> TestCache.get_or_compute(key, fn -> :never_called end) end)
        await_waiters(key, 1)

        send(leader_pid, {:finish, fn -> raise "computation blew up" end})

        assert Task.await(leader) == {:error, :computation_failed}
        assert Task.await(waiter) == {:error, :computation_failed}
      end)

    assert log =~ "Cache computation raised an exception"

    # The failure was not cached: the next caller computes again.
    assert TestCache.get_or_compute(key, fn -> :recovered end) == :recovered
  end

  test "a leader that dies mid-computation hands the work to a waiter" do
    key = "promotion"
    caller = self()

    {leader, leader_pid} = claim_lead(key)

    waiter =
      Task.async(fn ->
        TestCache.get_or_compute(key, fn ->
          send(caller, :waiter_computed)
          :from_waiter
        end)
      end)

    await_waiters(key, 1)

    # `Task.async` links, so drop the link before killing or the exit
    # propagates to the test process itself.
    Process.unlink(leader.pid)
    Process.exit(leader_pid, :kill)

    assert Task.await(waiter) == :from_waiter
    assert_received :waiter_computed
    assert TestCache.get_or_compute(key, fn -> :not_recomputed end) == :from_waiter
  end

  test "an error the caller asked not to cache still reaches the waiters" do
    key = "transient"

    {leader, leader_pid} = claim_lead(key, cache_errors: false)

    waiter =
      Task.async(fn ->
        TestCache.get_or_compute(key, fn -> :never_called end, :timer.seconds(5),
          cache_errors: false
        )
      end)

    await_waiters(key, 1)

    send(leader_pid, {:finish, fn -> {:error, :calendar_unavailable} end})

    assert Task.await(leader) == {:error, :calendar_unavailable}
    assert Task.await(waiter) == {:error, :calendar_unavailable}

    # Not stored, so the very next request retries rather than replaying it.
    assert TestCache.get_or_compute(key, fn -> :retried end) == :retried
  end

  # Starts a caller that wins the computation for `key` and parks inside its
  # computation until told what to return. Returns the task and the pid the
  # computation is running in — the same pid, which is the point.
  defp claim_lead(key, opts \\ []) do
    caller = self()

    task =
      Task.async(fn ->
        TestCache.get_or_compute(
          key,
          fn ->
            send(caller, {:leading, self()})

            receive do
              {:finish, produce} -> produce.()
            end
          end,
          :timer.seconds(5),
          opts
        )
      end)

    assert_receive {:leading, leader_pid}
    assert leader_pid == task.pid

    {task, leader_pid}
  end

  defp await_waiters(key, count) do
    eventually(
      fn -> assert length(waiters_for(key)) == count end,
      message: "expected #{count} caller(s) to be blocked waiting on #{inspect(key)}"
    )
  end

  defp waiters_for(key) do
    TestCache
    |> :sys.get_state()
    |> Map.fetch!(:pending)
    |> Map.get(key, %{waiters: []})
    |> Map.fetch!(:waiters)
  end
end
