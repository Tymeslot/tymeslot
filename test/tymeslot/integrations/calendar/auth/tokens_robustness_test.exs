defmodule Tymeslot.Integrations.Calendar.Auth.TokensRobustnessTest do
  use Tymeslot.DataCase, async: false # async: false to control ETS table state

  alias Tymeslot.Integrations.Calendar.Auth.TokenRefreshLock
  alias Tymeslot.Integrations.Calendar.Tokens

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

      assert {:ok, _} = Tokens.refresh_oauth_token(integration)
    end

    test "handles malformed integration maps" do
      # Missing ID - should still work (unlocked)
      integration = %{provider: "google", refresh_token: "ref"}

      expect(GoogleCalendarAPIMock, :refresh_token, 1, fn _int ->
        {:ok, {"new", "ref", DateTime.utc_now()}}
      end)

      assert {:ok, _} = Tokens.refresh_oauth_token(integration)
    end
  end

  describe "TokenRefreshLock lifecycle" do
    test "works even if init() wasn't called (table auto-created)" do
      # Ensure it's started if not already
      if !Process.whereis(TokenRefreshLock) do
        start_supervised!({TokenRefreshLock, []})
      end

      assert :ok = TokenRefreshLock.with_lock(:google, 999, fn -> :ok end)
    end

    test "releases lock automatically if process crashes" do
      # Ensure it's started
      if !Process.whereis(TokenRefreshLock) do
        start_supervised!({TokenRefreshLock, []})
      end

      parent = self()

      {pid, ref} = spawn_monitor(fn ->
        TokenRefreshLock.with_lock(:google, 123, fn ->
          send(parent, :locked)
          # Wait to be killed
          Process.sleep(:infinity)
        end)
      end)

      receive do
        :locked -> :ok
      after
        1000 -> flunk("Process failed to acquire lock")
      end

      # Verify it's locked
      assert {:error, :refresh_in_progress} = TokenRefreshLock.with_lock(:google, 123, fn -> :ok end)

      # Kill the process
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, :killed} -> :ok
      end

      # Give the GenServer a moment to process the :DOWN message
      Process.sleep(50)

      # Verify it's now unlocked
      assert :ok = TokenRefreshLock.with_lock(:google, 123, fn -> :ok end)
    end
  end
end
