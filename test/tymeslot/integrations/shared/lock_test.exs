defmodule Tymeslot.Integrations.Shared.LockTest do
  @moduledoc """
  Tests for integration lock mechanism to prevent concurrent operations.

  ## Note on Process.sleep Usage

  This test file intentionally uses `Process.sleep/1` to test concurrency behavior.
  Unlike most tests where sleep should be replaced with `eventually/2`, these sleeps
  are necessary to:

  1. Hold locks for a duration to simulate long-running operations
  2. Create race conditions to verify lock serialization works correctly
  3. Hold a lock while its holder is alive, however long that is

  These are integration tests for the locking mechanism itself, so the sleeps are
  part of the test design, not brittle timing dependencies.
  """

  # async: false because we are deleting a global ETS table
  use ExUnit.Case, async: false
  @moduletag :integrations

  import Tymeslot.TestHelpers.Eventually
  alias Tymeslot.Integrations.Shared.Lock

  @table :integration_operation_locks

  describe "with_lock/2" do
    test "ensures table exists when manager is running" do
      # Ensure it's started
      if !Process.whereis(Lock), do: Lock.start_link([])

      assert :ets.info(@table) != :undefined

      # Calling with_lock should succeed
      result = Lock.with_lock("test_key", fn -> :ok end)
      assert result == :ok
    end

    test "serializes execution" do
      test_pid = self()

      # Start a process that holds the lock
      spawn_link(fn ->
        Lock.with_lock("lock_456", fn ->
          send(test_pid, :locked)
          # Intentional sleep: Hold lock to simulate long-running operation
          # and verify that concurrent access is properly serialized
          Process.sleep(100)
        end)
      end)

      assert_receive :locked

      # Try to get the same lock
      assert {:error, :refresh_in_progress} =
               Lock.with_lock("lock_456", fn -> :ok end)
    end

    test "recovers from GenServer crash" do
      # Acquire a lock
      assert :ok = Lock.with_lock("temp_lock", fn -> :ok end)

      # Verify table exists
      assert :ets.info(@table) != :undefined

      # Kill the GenServer
      pid = Process.whereis(Lock)
      Process.exit(pid, :kill)

      # Wait for restart
      eventually(fn ->
        # Ensure the process is registered again and is a NEW pid
        new_pid = Process.whereis(Lock)
        assert is_pid(new_pid), "Lock GenServer was not restarted"
        assert new_pid != pid
        # New GenServer should have recreated the table
        assert :ets.info(@table) != :undefined
      end)

      # Should be able to acquire the "same" lock again because the old table is gone
      assert :ok = Lock.with_lock("temp_lock", fn -> :ok end)
    end

    test "keeps a lock with its holder for as long as the holder is alive" do
      key = "long_held_lock_123"
      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          Lock.with_lock(key, fn ->
            send(parent, :locked)
            Process.sleep(:infinity)
          end)
        end)

      assert_receive :locked, 1000

      # Backdate the entry far past any lease: a slow holder still has the
      # lock, because handing it on would let two callers overlap.
      long_ago = System.monotonic_time(:millisecond) - 3_600_000
      Lock.put_lock(key, long_ago, pid)

      assert {:error, :refresh_in_progress} = Lock.with_lock(key, fn -> :ok end)

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      eventually(fn -> assert :ok = Lock.with_lock(key, fn -> :ok end) end)
    end

    test "takes over an entry whose holder has died" do
      key = "dead_holder_lock_123"
      {pid, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      # put_lock does not monitor, so only the liveness check can free this.
      Lock.put_lock(key, System.monotonic_time(:millisecond), pid)

      assert :ok = Lock.with_lock(key, fn -> :ok end)
    end

    test "supports backward compatibility for calendar integrations" do
      assert :ok = Lock.with_lock(:google, 999, fn -> :ok end)

      # Should also block the tuple key
      test_pid = self()

      spawn_link(fn ->
        Lock.with_lock({:google, 999}, fn ->
          send(test_pid, :locked)
          Process.sleep(100)
        end)
      end)

      assert_receive :locked
      assert {:error, :refresh_in_progress} = Lock.with_lock(:google, 999, fn -> :ok end)
    end
  end
end
