defmodule Tymeslot.Integrations.Calendar.TokensTest do
  use Tymeslot.DataCase, async: true

  import Tymeslot.Factory
  import Mox

  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Tokens
  alias Tymeslot.Repo

  setup :verify_on_exit!

  describe "ensure_valid_token/2" do
    test "returns integration unchanged when token is not expired" do
      user = insert(:user)

      integration = %{
        provider: "google",
        access_token: "valid_token",
        refresh_token: "refresh_token",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      assert {:ok, result} = Tokens.ensure_valid_token(integration, user.id)
      assert result.access_token == "valid_token"
      assert result == integration
    end

    test "returns integration with nil expires_at as valid (CalDAV case)" do
      user = insert(:user)

      integration = %{
        provider: "caldav",
        access_token: "token",
        token_expires_at: nil
      }

      assert {:ok, result} = Tokens.ensure_valid_token(integration, user.id)
      assert result == integration
    end

    test "returns integration unchanged when token expires far in the future" do
      user = insert(:user)

      # Token expires in 1 week
      integration = %{
        provider: "google",
        access_token: "valid_token",
        refresh_token: "refresh_token",
        token_expires_at: DateTime.add(DateTime.utc_now(), 7 * 24 * 3600, :second)
      }

      assert {:ok, result} = Tokens.ensure_valid_token(integration, user.id)
      assert result.access_token == "valid_token"
    end

    test "attempts refresh when token is expired for Google provider" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token: "old_token",
          refresh_token: "refresh_token",
          token_expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        )

      expect(GoogleCalendarAPIMock, :refresh_token, fn _int ->
        {:ok, {"new_access", "new_refresh", DateTime.add(DateTime.utc_now(), 3600)}}
      end)

      assert {:ok, updated} = Tokens.ensure_valid_token(integration, user.id)
      assert updated.access_token == "new_access"
    end

    test "does not crash when refreshing a plain map integration" do
      # Plain map without schema struct
      integration = %{
        provider: "google",
        access_token: "old_token",
        refresh_token: "refresh_token",
        token_expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      }

      expect(GoogleCalendarAPIMock, :refresh_token, fn _int ->
        {:ok, {"new_access", "new_refresh", DateTime.add(DateTime.utc_now(), 3600)}}
      end)

      # Should attempt refresh and return success but NOT crash
      assert {:ok, updated} = Tokens.ensure_valid_token(integration, 1)
      assert updated.access_token == "new_access"
    end

    test "attempts refresh when token is expired for Outlook provider" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          access_token: "old_token",
          refresh_token: "refresh_token",
          token_expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        )

      expect(OutlookCalendarAPIMock, :refresh_token, fn _int ->
        {:ok,
         {"new_outlook_access", "new_outlook_refresh", DateTime.add(DateTime.utc_now(), 3600)}}
      end)

      assert {:ok, updated} = Tokens.ensure_valid_token(integration, user.id)
      assert updated.access_token == "new_outlook_access"
    end

    test "handles :authentication_error for Outlook provider" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          access_token: "old_token",
          refresh_token: "refresh_token",
          token_expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        )

      expect(OutlookCalendarAPIMock, :refresh_token, fn _int ->
        {:error, :authentication_error, "Outlook Client ID not configured"}
      end)

      # In Tokens.refresh_oauth_token, it maps {:error, type, msg} to {:error, {type, msg}}
      assert {:error, {:authentication_error, "Outlook Client ID not configured"}} =
               Tokens.ensure_valid_token(integration, user.id)
    end
  end

  describe "refresh_oauth_token/1" do
    test "returns error for unsupported provider" do
      integration = %{provider: "caldav"}

      assert {:error, :unsupported_provider} = Tokens.refresh_oauth_token(integration)
    end

    test "returns error for unknown provider" do
      integration = %{provider: "unknown_provider"}

      assert {:error, :unsupported_provider} = Tokens.refresh_oauth_token(integration)
    end

    test "attempts to refresh Google token with schema struct" do
      user = insert(:user)

      integration =
        CalendarIntegrationSchema.decrypt_oauth_tokens(
          insert(:calendar_integration,
            user: user,
            provider: "google",
            access_token: "old_token",
            refresh_token: "test_refresh_token",
            token_expires_at: DateTime.utc_now()
          )
        )

      expect(GoogleCalendarAPIMock, :refresh_token, fn _int ->
        {:ok, {"refreshed_access", "test_refresh_token", DateTime.add(DateTime.utc_now(), 3600)}}
      end)

      assert {:ok, updated} = Tokens.refresh_oauth_token(integration)
      assert updated.access_token == "refreshed_access"
      assert updated.refresh_token == "test_refresh_token"
    end

    test "handles Google refresh token rotation" do
      user = insert(:user)

      integration =
        CalendarIntegrationSchema.decrypt_oauth_tokens(
          insert(:calendar_integration,
            user: user,
            provider: "google",
            access_token: "old_token",
            refresh_token: "old_refresh_token",
            token_expires_at: DateTime.utc_now()
          )
        )

      expect(GoogleCalendarAPIMock, :refresh_token, fn _int ->
        {:ok, {"new_access", "new_rotated_refresh", DateTime.add(DateTime.utc_now(), 3600)}}
      end)

      assert {:ok, updated} = Tokens.refresh_oauth_token(integration)
      assert updated.access_token == "new_access"
      assert updated.refresh_token == "new_rotated_refresh"
    end

    test "attempts to refresh Outlook token with schema struct" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          access_token: "old_token",
          refresh_token: "test_refresh_token",
          token_expires_at: DateTime.utc_now()
        )

      expect(OutlookCalendarAPIMock, :refresh_token, fn _int ->
        {:ok,
         {"outlook_refreshed", "outlook_refreshed_refresh", DateTime.add(DateTime.utc_now(), 3600)}}
      end)

      assert {:ok, updated} = Tokens.refresh_oauth_token(integration)
      assert updated.access_token == "outlook_refreshed"
    end

    test "clears sync_error upon successful refresh" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          sync_error: "Old Error",
          token_expires_at: DateTime.utc_now()
        )

      expect(GoogleCalendarAPIMock, :refresh_token, fn _int ->
        {:ok, {"new_access", "refresh", DateTime.add(DateTime.utc_now(), 3600)}}
      end)

      assert {:ok, updated} = Tokens.refresh_oauth_token(integration)
      assert is_nil(updated.sync_error)

      # Also verify in DB
      fresh = Repo.get!(CalendarIntegrationSchema, integration.id)
      assert is_nil(fresh.sync_error)
    end

    test "handles malformed integration_id safely" do
      # Should not raise, just fallback to perform_refresh without lock
      integration = %{provider: "google", id: "not-an-integer", refresh_token: "ref"}

      expect(GoogleCalendarAPIMock, :refresh_token, 1, fn _int ->
        {:ok, {"new", "ref", DateTime.utc_now()}}
      end)

      assert {:ok, _} = Tokens.refresh_oauth_token(integration)
    end

    test "handles missing provider_atom safely" do
      # This should be caught by the when guard, but let's be sure.
      integration = %{provider: "unknown", id: 123}
      assert {:error, :unsupported_provider} = Tokens.refresh_oauth_token(integration)
    end
  end

  describe "token refresh behavior with different providers" do
    test "handles CalDAV provider correctly (no refresh needed)" do
      integration = %{
        provider: "caldav",
        username: "user",
        password: "pass"
      }

      assert {:error, :unsupported_provider} = Tokens.refresh_oauth_token(integration)
    end

    test "handles Nextcloud provider correctly (no OAuth refresh)" do
      integration = %{
        provider: "nextcloud",
        username: "user",
        password: "pass"
      }

      assert {:error, :unsupported_provider} = Tokens.refresh_oauth_token(integration)
    end
  end
end
