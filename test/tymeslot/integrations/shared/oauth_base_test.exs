defmodule Tymeslot.Integrations.Common.OAuthBaseTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Common.OAuthBase

  describe "validate_config/2" do
    test "validates required fields" do
      config = %{
        access_token: "at",
        refresh_token: "rt",
        token_expires_at: DateTime.utc_now(),
        oauth_scope: "scope"
      }

      assert :ok = OAuthBase.validate_config(config, fn _client -> :ok end)

      assert {:error, message} = OAuthBase.validate_config(%{}, fn _client -> :ok end)
      assert message =~ "Missing required fields"
    end

    test "calls scope validator if fields are present" do
      config = %{
        access_token: "at",
        refresh_token: "rt",
        token_expires_at: DateTime.utc_now(),
        oauth_scope: "scope"
      }

      assert {:error, "invalid scope"} =
               OAuthBase.validate_config(config, fn _client -> {:error, "invalid scope"} end)
    end
  end

  describe "new/2" do
    test "returns ok tuple on success" do
      config = %{
        access_token: "at",
        refresh_token: "rt",
        token_expires_at: DateTime.utc_now(),
        oauth_scope: "scope"
      }

      assert {:ok, ^config} = OAuthBase.new(config, fn _client -> :ok end)
    end

    test "returns error on failure" do
      assert {:error, _reason} = OAuthBase.new(%{}, fn _client -> :ok end)
    end
  end

  describe "time helpers" do
    test "default_start_time/0 returns a time in the past" do
      now = DateTime.utc_now()
      start = OAuthBase.default_start_time()
      assert DateTime.compare(start, now) == :lt
    end

    test "default_end_time/0 returns a time in the future" do
      now = DateTime.utc_now()
      finish = OAuthBase.default_end_time()
      assert DateTime.compare(finish, now) == :gt
    end
  end

  describe "handle_api_call/2" do
    test "handles ok results" do
      assert {:ok, "RESULT"} =
               OAuthBase.handle_api_call(fn -> {:ok, "result"} end, &String.upcase/1)

      assert :ok = OAuthBase.handle_api_call(fn -> :ok end)
    end

    test "handles error results" do
      assert {:error, "reason"} = OAuthBase.handle_api_call(fn -> {:error, "reason"} end)
    end

    # Callers above this layer dispatch on the atom: CalendarEventSync recreates
    # an event on :not_found, CalendarEventWorker discards on :unauthorized.
    # Returning the provider's message instead made those branches unreachable.
    test "keeps the classification atom from a typed provider error" do
      assert {:error, :not_found} =
               OAuthBase.handle_api_call(fn -> {:error, :not_found, "Event not found"} end)

      assert {:error, :unauthorized} =
               OAuthBase.handle_api_call(fn ->
                 {:error, :unauthorized, "Token expired or invalid"}
               end)
    end
  end

  describe "create_or_update_integration/4" do
    test "creates a new integration if none exists" do
      user = insert(:user)
      insert(:profile, user: user)

      tokens = %{
        access_token: "at",
        refresh_token: "rt",
        expires_at: DateTime.utc_now(),
        scope: "scope"
      }

      assert {:ok, integration} =
               OAuthBase.create_or_update_integration(
                 user.id,
                 "google",
                 %{name: "My Cal", base_url: "https://google.com"},
                 tokens
               )

      assert integration.user_id == user.id
      assert integration.provider == "google"

      # Decrypt to check virtual fields
      integration =
        CalendarIntegrationSchema.decrypt_oauth_tokens(integration)

      assert integration.access_token == "at"
    end

    test "updates existing integration" do
      user = insert(:user)
      insert(:profile, user: user)

      existing =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token: "old",
          base_url: "https://google.com"
        )

      tokens = %{
        access_token: "new",
        refresh_token: "rt",
        expires_at: DateTime.utc_now(),
        scope: "scope"
      }

      assert {:ok, updated} =
               OAuthBase.create_or_update_integration(user.id, "google", %{}, tokens)

      assert updated.id == existing.id

      # Decrypt to check virtual fields
      updated = CalendarIntegrationSchema.decrypt_oauth_tokens(updated)
      assert updated.access_token == "new"
    end
  end
end
