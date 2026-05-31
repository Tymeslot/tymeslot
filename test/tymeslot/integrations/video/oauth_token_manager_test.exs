defmodule Tymeslot.Integrations.Video.OAuthTokenManagerTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Video.OAuthTokenManager

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
end
