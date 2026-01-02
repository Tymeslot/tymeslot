defmodule Tymeslot.Integrations.Calendar.TokensConcurrencyTest do
  use Tymeslot.DataCase, async: false # async: false to avoid ETS table issues if not careful

  import Mox
  alias Tymeslot.Integrations.Calendar.Auth.TokenRefreshLock
  alias Tymeslot.Integrations.Calendar.Tokens

  setup :verify_on_exit!

  describe "refresh_oauth_token concurrency" do
    test "only allows one refresh at a time for the same integration" do
      # We'll use a shared integration ID
      integration_id = 999_888
      integration = %{
        id: integration_id,
        provider: "google",
        access_token: "old_token",
        refresh_token: "refresh_token",
        token_expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      }

      # Setup mock to block briefly to simulate work
      test_pid = self()

      expect(GoogleCalendarAPIMock, :refresh_token, 1, fn _int ->
        # Send message to parent to signal we started
        send(test_pid, :refresh_started)

        # Block for 100ms
        Process.sleep(100)

        {:ok, {"new_access", "new_refresh", DateTime.add(DateTime.utc_now(), 3600)}}
      end)

      # Start first refresh in a task
      task1 = Task.async(fn -> Tokens.refresh_oauth_token(integration) end)

      # Wait for first refresh to start
      assert_receive :refresh_started, 500

      # Try second refresh immediately - should fail with :refresh_in_progress
      assert {:error, :refresh_in_progress} = Tokens.refresh_oauth_token(integration)

      # Wait for first refresh to finish
      assert {:ok, updated} = Task.await(task1)
      assert updated.access_token == "new_access"
    end

    test "handles expired locks gracefully" do
      # This test manually inserts an "old" lock to verify expiration logic
      integration_id = 777_666

      # Insert lock from far in the past using the new helper
      old_now = System.monotonic_time(:millisecond) - 3_600_000
      TokenRefreshLock.put_lock(:google, integration_id, old_now, self())

      integration = %{
        id: integration_id,
        provider: "google",
        access_token: "old_token",
        refresh_token: "refresh_token",
        token_expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      }

      expect(GoogleCalendarAPIMock, :refresh_token, 1, fn _int ->
        {:ok, {"recovered_access", "refresh", DateTime.add(DateTime.utc_now(), 3600)}}
      end)

      # Should succeed because the existing lock is expired
      assert {:ok, updated} = Tokens.refresh_oauth_token(integration)
      assert updated.access_token == "recovered_access"
    end

    test "double-checks expiry after acquiring lock to avoid redundant refresh" do
      import Tymeslot.Factory
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token: "old",
          token_expires_at: DateTime.add(DateTime.utc_now(), -3600)
        )

      # First process will actually refresh
      expect(GoogleCalendarAPIMock, :refresh_token, 1, fn _int ->
        {:ok, {"new", "refresh", DateTime.add(DateTime.utc_now(), 3600)}}
      end)

      # Run first refresh to completion
      assert {:ok, _updated1} = Tokens.refresh_oauth_token(integration)

      # Second process starts with the SAME (stale) integration map
      # It should acquire lock, then RE-FETCH from DB, see it's NOT expired, and skip API call.
      # (Mock expect is 1, so if it calls again, Mox will fail on exit or during call if configured)
      assert {:ok, updated2} = Tokens.refresh_oauth_token(integration)

      # Second one should have the NEW token from DB re-fetch
      assert updated2.access_token == "new"
    end

    test "skips locking when integration ID is unknown" do
      # Ad-hoc map without ID
      integration = %{
        provider: "google",
        access_token: "old",
        token_expires_at: DateTime.add(DateTime.utc_now(), -3600)
      }

      expect(GoogleCalendarAPIMock, :refresh_token, 2, fn _int ->
        {:ok, {"new", "refresh", DateTime.add(DateTime.utc_now(), 3600)}}
      end)

      # These should BOTH run because they don't lock on :unknown
      assert {:ok, _} = Tokens.refresh_oauth_token(integration)
      assert {:ok, _} = Tokens.refresh_oauth_token(integration)
    end

    test "slow refresh does not allow second process to 'steal' the lock prematurely" do
      # This test verifies that even if a refresh takes a long time,
      # as long as it's within the timeout (now 90s), a second process
      # will still see the lock as active.
      integration_id = 555_444
      integration = %{
        id: integration_id,
        provider: "google",
        access_token: "old",
        refresh_token: "ref",
        token_expires_at: DateTime.add(DateTime.utc_now(), -3600)
      }

      test_pid = self()

      # First caller blocks for 500ms (much less than 90s, but enough to test concurrency)
      expect(GoogleCalendarAPIMock, :refresh_token, 1, fn _int ->
        send(test_pid, :first_started)
        Process.sleep(500)
        {:ok, {"new", "ref", DateTime.add(DateTime.utc_now(), 3600)}}
      end)

      task1 = Task.async(fn -> Tokens.refresh_oauth_token(integration) end)

      assert_receive :first_started, 1000

      # Second caller should get :refresh_in_progress immediately
      assert {:error, :refresh_in_progress} = Tokens.refresh_oauth_token(integration)

      # Wait for first one to finish
      assert {:ok, _} = Task.await(task1)
    end
  end
end
