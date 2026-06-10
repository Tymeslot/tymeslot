defmodule Tymeslot.Integrations.Video.OAuthTokenManagerTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Video.OAuthTokenManager
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries

  describe "token_still_valid?/1" do
    test "returns false when expiry is unknown" do
      refute OAuthTokenManager.token_still_valid?(nil)
    end

    test "returns true when expiry is further out than the 300s buffer" do
      # 301s out — just past the buffer.
      expires_at = DateTime.add(DateTime.utc_now(), 301, :second)
      assert OAuthTokenManager.token_still_valid?(expires_at)
    end

    test "returns false at the buffer boundary" do
      # Exactly 300s out is not strictly greater than the buffer, so it must
      # be treated as needing refresh.
      expires_at = DateTime.add(DateTime.utc_now(), 300, :second)
      refute OAuthTokenManager.token_still_valid?(expires_at)
    end

    test "returns false when the token is inside the buffer window" do
      expires_at = DateTime.add(DateTime.utc_now(), 60, :second)
      refute OAuthTokenManager.token_still_valid?(expires_at)
    end

    test "returns false for an already-expired token" do
      expires_at = DateTime.add(DateTime.utc_now(), -10, :second)
      refute OAuthTokenManager.token_still_valid?(expires_at)
    end
  end

  describe "refresh_with_lock/2 without integration_id/user_id" do
    test "invokes the fallback refresh hook directly, bypassing the lock" do
      config = %{access_token: "stale", refresh_token: "ref"}

      result =
        OAuthTokenManager.refresh_with_lock(config, %{
          provider: :test_provider,
          refresh: fn _config -> {:ok, "in-lock-token"} end,
          already_refreshed: fn _config, _decrypted -> {:ok, "already"} end,
          fallback_refresh: fn cfg -> {:ok, {:fallback, cfg}} end
        })

      assert result == {:ok, {:fallback, config}}
    end

    test "falls back to the :refresh hook when no :fallback_refresh is supplied" do
      config = %{refresh_token: "ref"}

      result =
        OAuthTokenManager.refresh_with_lock(config, %{
          provider: :test_provider,
          refresh: fn _config -> {:ok, "refresh-token"} end,
          already_refreshed: fn _config, _decrypted -> {:ok, "already"} end
        })

      assert result == {:ok, "refresh-token"}
    end
  end

  describe "refresh_with_lock/2 locked double-check branches" do
    test "invokes :already_refreshed when the DB token is still valid" do
      %{config: config} = setup_integration_config(expires_in_seconds: 3600)

      result =
        OAuthTokenManager.refresh_with_lock(config, locked_hooks())

      assert result == {:ok, {:already_refreshed, "fresh-db-token"}}
    end

    test "invokes :refresh when the DB token is still inside the expiry buffer" do
      %{config: config} = setup_integration_config(expires_in_seconds: -10)

      result =
        OAuthTokenManager.refresh_with_lock(config, locked_hooks())

      assert result == {:ok, :refreshed}
    end

    test "invokes :refresh when the integration vanished mid-flight" do
      config = %{
        access_token: "stale",
        integration_id: 9_999_999,
        user_id: 9_999_999
      }

      result =
        OAuthTokenManager.refresh_with_lock(config, locked_hooks())

      assert result == {:ok, :refreshed}
    end
  end

  describe "refresh_with_lock/3 with force: true" do
    test "skips the validity double-check and always runs :refresh" do
      # Token is comfortably valid, so the unforced path would short-circuit to
      # :already_refreshed. Forcing must bypass that and refresh anyway.
      #
      # The config access_token matches the DB token — no sibling has refreshed —
      # so the forced path must not short-circuit to :already_refreshed and must
      # call :refresh instead.
      user = insert(:user)

      {:ok, integration} =
        VideoIntegrationQueries.create(%{
          user_id: user.id,
          name: "Zoom",
          provider: "zoom",
          access_token: "still-the-same-token",
          refresh_token: "db-refresh",
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          oauth_scope: "meeting:write:meeting"
        })

      config = %{
        access_token: "still-the-same-token",
        integration_id: integration.id,
        user_id: user.id
      }

      result = OAuthTokenManager.refresh_with_lock(config, locked_hooks(), force: true)

      assert result == {:ok, :refreshed}
    end

    test "does not force when force: false (default)" do
      %{config: config} = setup_integration_config(expires_in_seconds: 3600)

      assert {:ok, {:already_refreshed, _token}} =
               OAuthTokenManager.refresh_with_lock(config, locked_hooks(), force: false)
    end

    test "returns fresh DB token without re-refreshing when a sibling already rotated it" do
      # Scenario: two processes both hit a 401 and call refresh_with_lock(force:
      # true) concurrently. The lock serialises them. The first completes and
      # stores a new access_token in the DB. The second should detect the change
      # and return the DB-fresh token via :already_refreshed — NOT call :refresh
      # again with the now-stale (pre-first-rotation) refresh token.
      user = insert(:user)

      {:ok, integration} =
        VideoIntegrationQueries.create(%{
          user_id: user.id,
          name: "Zoom",
          provider: "zoom",
          # Sibling has already stored the new token in the DB.
          access_token: "rotated-by-sibling-token",
          refresh_token: "new-refresh-after-rotation",
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          oauth_scope: "meeting:write:meeting"
        })

      # This process still holds the pre-rotation access token that got the 401.
      config = %{
        access_token: "pre-rotation-token",
        integration_id: integration.id,
        user_id: user.id
      }

      refresh_called? = :counters.new(1, [])

      hooks = %{
        provider: :zoom,
        refresh: fn _config ->
          :counters.add(refresh_called?, 1, 1)
          {:ok, :should_not_be_called}
        end,
        already_refreshed: fn _config, decrypted ->
          {:ok, {:already_refreshed, decrypted.access_token}}
        end
      }

      result = OAuthTokenManager.refresh_with_lock(config, hooks, force: true)

      assert result == {:ok, {:already_refreshed, "rotated-by-sibling-token"}}
      assert :counters.get(refresh_called?, 1) == 0
    end

    test "uses the DB-fresh refresh token when the forced refresh is still needed" do
      # Scenario: the forced path re-reads the DB but the access token has NOT
      # changed (no sibling refreshed yet). The :refresh hook must receive the
      # DB-fresh config so Zoom does not reject a stale pre-rotation refresh token.
      user = insert(:user)

      {:ok, integration} =
        VideoIntegrationQueries.create(%{
          user_id: user.id,
          name: "Zoom",
          provider: "zoom",
          # DB token matches what the caller has — no sibling rotation happened.
          access_token: "still-rejected-token",
          refresh_token: "latest-db-refresh-token",
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          oauth_scope: "meeting:write:meeting"
        })

      config = %{
        # Caller's in-memory config has an older refresh token captured before
        # the lock — simulates a process that was queued while another refreshed.
        access_token: "still-rejected-token",
        refresh_token: "older-in-memory-refresh-token",
        integration_id: integration.id,
        user_id: user.id
      }

      received_refresh_token = :ets.new(:test_capture, [:set, :public])

      hooks = %{
        provider: :zoom,
        refresh: fn received_config ->
          :ets.insert(received_refresh_token, {:refresh_token, received_config.refresh_token})
          {:ok, :refreshed}
        end,
        already_refreshed: fn _config, _decrypted -> {:ok, :already_refreshed} end
      }

      result = OAuthTokenManager.refresh_with_lock(config, hooks, force: true)

      assert result == {:ok, :refreshed}

      [{:refresh_token, used_token}] = :ets.lookup(received_refresh_token, :refresh_token)
      # Must use the DB-fresh refresh token, not the stale in-memory one.
      assert used_token == "latest-db-refresh-token"
      refute used_token == "older-in-memory-refresh-token"

      :ets.delete(received_refresh_token)
    end

    test "falls back to stale config when integration vanished during forced refresh" do
      config = %{
        access_token: "rejected-token",
        integration_id: 9_999_998,
        user_id: 9_999_998
      }

      result = OAuthTokenManager.refresh_with_lock(config, locked_hooks(), force: true)

      assert result == {:ok, :refreshed}
    end
  end

  defp locked_hooks do
    %{
      provider: :zoom,
      refresh: fn _config -> {:ok, :refreshed} end,
      already_refreshed: fn _config, decrypted ->
        {:ok, {:already_refreshed, decrypted.access_token}}
      end
    }
  end

  defp setup_integration_config(opts) do
    expires_in = Keyword.fetch!(opts, :expires_in_seconds)
    user = insert(:user)

    {:ok, integration} =
      VideoIntegrationQueries.create(%{
        user_id: user.id,
        name: "Zoom",
        provider: "zoom",
        access_token: "fresh-db-token",
        refresh_token: "db-refresh",
        token_expires_at: DateTime.add(DateTime.utc_now(), expires_in, :second),
        oauth_scope: "meeting:write:meeting"
      })

    config = %{
      access_token: "current-process-token",
      integration_id: integration.id,
      user_id: user.id
    }

    %{user: user, integration: integration, config: config}
  end
end
