defmodule Tymeslot.Integrations.Calendar.Auth.TokensRobustnessTest do
  @moduletag :integrations
  @moduledoc """
  @moduletag :integrations
  Robustness tests for token refresh error handling and lock recovery.

  ## Note on Process.sleep Usage

  This test file intentionally uses `Process.sleep/1` to test edge cases in
  the locking mechanism:

  1. `Process.sleep(:infinity)` - Holds a lock indefinitely to test cleanup
     when the process is killed
  2. Short sleeps - Allow time for async cleanup operations (monitor messages)
     to be processed by GenServers

  These sleeps are necessary for testing process lifecycle and cleanup behavior,
  not timing dependencies.
  """

  # async: false to control ETS table state
  use Tymeslot.DataCase, async: false

  alias Tymeslot.Integrations.Calendar.Tokens
  alias Tymeslot.Integrations.Shared.Lock

  import Mox
  setup :verify_on_exit!

  describe "refresh_oauth_token robustness" do
    test "handles non-integer string integration_id safely" do
      # Should not raise, just fallback to perform_refresh without lock
      integration = %{provider: "google", id: "not-an-integer", refresh_token: "ref"}

      # Mock the actual refresh call
      expect(GoogleCalendarAPIMock, :refresh_token, 1, fn _int ->
        {:ok, {"new", "ref", DateTime.utc_now()}}
      end)

      assert {:ok, _result} = Tokens.refresh_oauth_token(integration)
    end

    test "handles malformed integration maps" do
      # Missing ID - should still work (unlocked)
      integration = %{provider: "google", refresh_token: "ref"}

      expect(GoogleCalendarAPIMock, :refresh_token, 1, fn _int ->
        {:ok, {"new", "ref", DateTime.utc_now()}}
      end)

      assert {:ok, _result} = Tokens.refresh_oauth_token(integration)
    end
  end

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

      # Intentional sleep: Allow GenServer time to process the :DOWN monitor
      # message and remove the lock entry from ETS. This is testing async
      # cleanup behavior, not a timing dependency - the GenServer needs time
      # to process its mailbox
      Process.sleep(50)

      # Verify it's now unlocked
      assert :ok = Lock.with_lock(:google, 123, fn -> :ok end)
    end
  end
end
