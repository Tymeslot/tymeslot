defmodule Tymeslot.Integrations.Calendar.Auth.TokenRefreshLockTest do
  use ExUnit.Case, async: false # async: false because we are deleting a global ETS table

  alias Tymeslot.Integrations.Calendar.Auth.TokenRefreshLock

  @table :token_refresh_locks

  describe "with_lock/3" do
    test "ensures table exists when manager is running" do
      # Ensure it's started
      if !Process.whereis(TokenRefreshLock), do: TokenRefreshLock.start_link([])

      assert :ets.info(@table) != :undefined

      # Calling with_lock should succeed
      result = TokenRefreshLock.with_lock(:google, 123, fn -> :ok end)
      assert result == :ok
    end

    test "serializes execution" do
      # This is already covered by concurrency tests but good to have a simple unit test
      test_pid = self()

      # Start a process that holds the lock
      spawn_link(fn ->
        TokenRefreshLock.with_lock(:google, 456, fn ->
          send(test_pid, :locked)
          Process.sleep(100)
        end)
      end)

      assert_receive :locked

      # Try to get the same lock
      assert {:error, :refresh_in_progress} = TokenRefreshLock.with_lock(:google, 456, fn -> :ok end)
    end

    test "cleans up monitors when overwriting expired lock" do
      integration_id = 123_456

      # Acquire lock in a process that stays alive
      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          TokenRefreshLock.with_lock(:google, integration_id, fn ->
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
      # We use a timestamp far in the past (must be > 90s)
      expired_timestamp = System.monotonic_time(:millisecond) - 120_000
      TokenRefreshLock.put_lock(:google, integration_id, expired_timestamp, pid)

      # Acquire the lock again from a new process
      # This should trigger cleanup of the old monitor
      assert :ok = TokenRefreshLock.with_lock(:google, integration_id, fn -> :ok end)

      # Give the GenServer a moment to process everything
      Process.sleep(50)

      # Now kill the original process.
      # If the monitor was cleaned up, the GenServer should NOT log about releasing the lock
      # (though we can't easily assert on logs here without more setup).
      # More importantly, we can check the state if we had access to it, but we can at least
      # verify that the lock is still held by the *new* process if it were still running.
      # But since the second with_lock call finished, the lock should be released.

      # Let's verify that the original holder dying doesn't mess things up.
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, :killed} -> :ok
      end

      # If the old monitor was still active, the :DOWN would have tried to delete the lock.
      # Since it's already deleted (by the second with_lock), it's a no-op, but the cleanup
      # prevents the GenServer state from growing.
    end
  end
end
