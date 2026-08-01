defmodule Tymeslot.Integrations.Shared.LockTest do
  @moduledoc """
  Tests for integration lock mechanism to prevent concurrent operations.

  ## Note on Process.sleep Usage

  This test file intentionally uses `Process.sleep/1` to test concurrency behavior.
  Unlike most tests where sleep should be replaced with `eventually/2`, these sleeps
  are necessary to:

  1. Hold locks for a duration to simulate long-running operations
  2. Create race conditions to verify lock serialization works correctly
  3. Test timeout and expiration logic

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

    test "cleans up monitors when overwriting expired lock" do
      key = "expired_lock_123"

      # Acquire lock in a process that stays alive
      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          Lock.with_lock(key, fn ->
            send(parent, :locked)
            Process.sleep(:infinity)
          end)
        end)

      receive do
        :locked -> :ok
      after
        1000 -> flunk("Failed to acquire initial lock")
      end

      # Expire the lock manually via test helper
      expired_timestamp = System.monotonic_time(:millisecond) - 120_000
      Lock.put_lock(key, expired_timestamp, pid)

      # Acquire the lock again from a new process
      assert :ok = Lock.with_lock(key, fn -> :ok end)

      Process.exit(pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
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

    test "uses configured timeout" do
      # Set a very short timeout for :test_provider
      Application.put_env(:tymeslot, :integration_locks, test_provider: 50)

      key = :test_provider

      # Acquire lock
      assert :ok =
               Lock.with_lock(key, fn ->
                 # Wait until just after timeout
                 Process.sleep(100)
                 :ok
               end)

      # Now it should be acquirable because it's expired (even if process still runs)
      # Wait a bit for the old lock to be considered expired
      eventually(fn ->
        assert :ok = Lock.with_lock(key, fn -> :ok end)
      end)

      # Clean up config
      Application.delete_env(:tymeslot, :integration_locks)
    end
  end
end
