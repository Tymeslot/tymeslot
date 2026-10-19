defmodule Tymeslot.Integrations.Calendar.Providers.OAuthBaseTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.Providers.OAuthBase

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
    # The shared response envelope carries a 429's Retry-After as
    # "retry_after:<n>"; the wait reaches CalendarEventWorker as seconds.
    test "keeps the wait a rate limit asked for" do
      assert {:error, {:rate_limited, 30}} =
               OAuthBase.handle_api_call(fn -> {:error, :rate_limited, "retry_after:30"} end)

      assert {:error, :rate_limited} =
               OAuthBase.handle_api_call(fn -> {:error, :rate_limited, "Too many requests"} end)
    end

    test "keeps the classification atom from a typed provider error" do
      assert {:error, :not_found} =
               OAuthBase.handle_api_call(fn -> {:error, :not_found, "Event not found"} end)

      assert {:error, :unauthorized} =
               OAuthBase.handle_api_call(fn ->
                 {:error, :unauthorized, "Token expired or invalid"}
               end)
    end
  end
end
