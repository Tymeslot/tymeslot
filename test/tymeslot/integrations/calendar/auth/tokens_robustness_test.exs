defmodule Tymeslot.Integrations.Calendar.Auth.TokensRobustnessTest do
  @moduledoc """
  Robustness tests for lock recovery around token refreshes.

  ## Note on Process.sleep Usage

  This test file intentionally uses `Process.sleep/1` to test edge cases in
  the locking mechanism:

  `Process.sleep(:infinity)` holds a lock indefinitely to test cleanup when
  the holder is killed. The lock owner learns of the death from its own
  `:DOWN` message, which nothing orders against the test's, so the test polls
  for the release rather than waiting a fixed time.
  """

  # async: false to control ETS table state
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  alias Tymeslot.Integrations.Shared.Lock
  alias Tymeslot.TestHelpers.Eventually

  describe "Lock lifecycle" do
    test "works even if init() wasn't called (table auto-created)" do
      # Ensure it's started if not already
      if !Process.whereis(Lock) do
        start_supervised!({Lock, []})
      end

      assert :ok = Lock.with_lock(:google, 999, fn -> :ok end)
    end

    test "releases lock automatically if process crashes" do
      # Ensure it's started
      if !Process.whereis(Lock) do
        start_supervised!({Lock, []})
      end

      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          Lock.with_lock(:google, 123, fn ->
            send(parent, :locked)
            # Intentional sleep: Hold lock indefinitely to test cleanup
            # when the process is killed - verifies that monitor-based
            # cleanup releases the lock properly
            Process.sleep(:infinity)
          end)
        end)

      receive do
        :locked -> :ok
      after
        1000 -> flunk("Process failed to acquire lock")
      end

      # Verify it's locked
      assert {:error, :refresh_in_progress} =
               Lock.with_lock(:google, 123, fn -> :ok end)

      # Kill the process
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, :killed} -> :ok
      end

      # A refused acquire changes nothing, so polling it is safe.
      Eventually.eventually(fn -> assert :ok = Lock.with_lock(:google, 123, fn -> :ok end) end)
    end
  end
end
