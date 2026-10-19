defmodule Tymeslot.Integrations.Video.Providers.OAuthRoomTest do
  use Tymeslot.DataCase, async: true

  @moduletag :integrations

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Video.Providers.OAuthRoom
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema

  # Stands in for a provider's OAuth helper: records each refresh it is asked
  # for and answers what the test put in the process dictionary.
  defmodule FakeHelper do
    @moduledoc false

    @spec refresh_access_token(String.t() | nil, String.t() | nil, keyword()) ::
            {:ok, map()} | {:error, term()}
    def refresh_access_token(refresh_token, scope, _opts) do
      send(self(), {:refreshed_with, refresh_token, scope})
      Process.get(:refresh_result)
    end
  end

  defp spec(overrides \\ %{}) do
    Map.merge(
      %{
        helper: FakeHelper,
        label: "Fake",
        validate_token: fn _config -> {:ok, :needs_refresh} end,
        scope: fn _config -> nil end,
        persist_failure: :best_effort
      },
      overrides
    )
  end

  defp in_seconds(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  defp refresh_returns(result), do: Process.put(:refresh_result, result)

  defp new_tokens(overrides \\ %{}) do
    Map.merge(
      %{
        access_token: "new-access",
        refresh_token: "new-refresh",
        expires_at: in_seconds(3600),
        scope: "new-scope"
      },
      overrides
    )
  end

  defp stored_integration(expires_in) do
    user = insert(:user)

    {:ok, integration} =
      VideoIntegrationQueries.create(%{
        user_id: user.id,
        name: "Zoom",
        provider: "zoom",
        access_token: "stored-access",
        refresh_token: "stored-refresh",
        token_expires_at: in_seconds(expires_in),
        oauth_scope: "stored-scope"
      })

    config = %{
      access_token: "caller-access",
      refresh_token: "caller-refresh",
      integration_id: integration.id,
      user_id: user.id
    }

    {integration, config}
  end

  defp stored(integration),
    do: VideoIntegrationSchema.decrypt_credentials(Repo.reload!(integration))

  describe "ensure_valid_token/3" do
    test "keeps a token the provider's own check accepts" do
      {_integration, config} = stored_integration(-60)
      spec = spec(%{validate_token: fn _config -> {:ok, :valid} end})

      assert {:ok, ^config} = OAuthRoom.ensure_valid_token(config, spec)
      refute_received {:refreshed_with, _token, _scope}
    end

    test "answers from the row when a sibling refreshed it already" do
      {_integration, config} = stored_integration(3600)

      assert {:ok, %{access_token: "stored-access"}} =
               OAuthRoom.ensure_valid_token(config, spec())

      refute_received {:refreshed_with, _token, _scope}
    end

    # Zoom and Microsoft rotate refresh tokens: a caller's copy taken before a
    # sibling's refresh holds one the provider has retired.
    test "refreshes with the stored refresh token and writes the result" do
      {integration, config} = stored_integration(-60)
      refresh_returns({:ok, new_tokens()})

      assert {:ok, %{access_token: "new-access", refresh_token: "new-refresh"}} =
               OAuthRoom.ensure_valid_token(config, spec())

      assert_received {:refreshed_with, "stored-refresh", nil}

      assert %{access_token: "new-access", refresh_token: "new-refresh"} = stored(integration)
      assert Repo.reload!(integration).oauth_scope == "new-scope"
    end

    test "asks for the scope the spec names" do
      {_integration, config} = stored_integration(-60)
      refresh_returns({:ok, new_tokens()})

      OAuthRoom.ensure_valid_token(config, spec(%{scope: &Map.get(&1, :oauth_scope)}))

      assert_received {:refreshed_with, _token, "stored-scope"}
    end

    # Writing the access token, or nothing, in their place would break the
    # next refresh, or clear a scope the integration still holds.
    test "keeps the stored refresh token and scope when the provider omits them" do
      {integration, config} = stored_integration(-60)
      refresh_returns({:ok, new_tokens(%{refresh_token: nil, scope: nil})})

      assert {:ok, _config} = OAuthRoom.ensure_valid_token(config, spec())

      assert %{access_token: "new-access", refresh_token: "stored-refresh"} = stored(integration)
      assert Repo.reload!(integration).oauth_scope == "stored-scope"
    end

    test "returns a refused refresh with its reason, writing nothing" do
      {integration, config} = stored_integration(-60)
      refresh_returns({:error, "Token refresh failed: invalid_grant"})

      assert {:error, "Token refresh failed: invalid_grant"} =
               OAuthRoom.ensure_valid_token(config, spec())

      assert %{access_token: "stored-access"} = stored(integration)
    end

    test "refreshes a transient config without a row, writing nothing" do
      refresh_returns({:ok, new_tokens()})

      assert {:ok, %{access_token: "new-access"}} =
               OAuthRoom.ensure_valid_token(%{refresh_token: "probe-refresh"}, spec())

      assert_received {:refreshed_with, "probe-refresh", nil}
    end

    test "refreshes the caller's copy of an integration deleted mid-flight" do
      config = %{refresh_token: "caller-refresh", integration_id: 9_999_999, user_id: 9_999_999}
      refresh_returns({:ok, new_tokens()})

      assert {:ok, %{access_token: "new-access"}} = OAuthRoom.ensure_valid_token(config, spec())
      assert_received {:refreshed_with, "caller-refresh", nil}
    end

    test "reports a token the provider's check refuses" do
      spec = spec(%{validate_token: fn _config -> {:error, "malformed"} end})

      assert {:error, "Token validation failed: malformed"} =
               OAuthRoom.ensure_valid_token(%{}, spec)
    end
  end

  describe "ensure_valid_token/3 after a 401" do
    test "refreshes a refused token whose stored expiry still looks good" do
      {_integration, config} = stored_integration(3600)
      refresh_returns({:ok, new_tokens()})

      assert {:ok, %{access_token: "new-access"}} =
               OAuthRoom.ensure_valid_token(config, spec(), refused_token: "stored-access")

      assert_received {:refreshed_with, "stored-refresh", nil}
    end

    test "uses a token a sibling has already replaced the refused one with" do
      {_integration, config} = stored_integration(3600)

      assert {:ok, %{access_token: "stored-access"}} =
               OAuthRoom.ensure_valid_token(config, spec(), refused_token: "older-refused-access")

      refute_received {:refreshed_with, _token, _scope}
    end

    # The operation refreshed at its start, so the token that drew the 401 is
    # the stored one, not the older one its config still carries. Comparing
    # with the config's token would hand the refused token straight back, the
    # retry would 401 again, and the integration would be flagged for a
    # reconnect it does not need.
    test "refreshes when the refused token is the one the operation refreshed to" do
      {_integration, config} = stored_integration(3600)
      config = %{config | access_token: "older-config-access"}
      refresh_returns({:ok, new_tokens()})

      assert {:ok, %{access_token: "new-access"}} =
               OAuthRoom.ensure_valid_token(config, spec(), refused_token: "stored-access")
    end
  end

  describe "a refreshed token that cannot be written" do
    setup do
      {integration, config} = stored_integration(-60)
      # A name the changeset refuses makes the token write fail.
      Repo.update_all(VideoIntegrationSchema, set: [name: ""])
      refresh_returns({:ok, new_tokens()})
      %{integration: integration, config: config}
    end

    # Zoom: the provider has already invalidated the old refresh token.
    test "fails the refresh for a provider that rotates refresh tokens", %{config: config} do
      assert {:error, :token_persist_failed} =
               OAuthRoom.ensure_valid_token(config, spec(%{persist_failure: :fatal}))
    end

    test "is used anyway when the stored credentials stay good", %{config: config} do
      assert {:ok, %{access_token: "new-access"}} =
               OAuthRoom.ensure_valid_token(config, spec(%{persist_failure: :best_effort}))
    end
  end

  describe "classify_token_result/1" do
    test "keeps a refused grant out of the breaker's reach" do
      assert {:error, "Token refresh failed: invalid_grant"} =
               OAuthRoom.classify_token_result({:error, "Token refresh failed: invalid_grant"})
    end

    test "hands anything else to the breaker" do
      assert {:provider_error, "timeout"} = OAuthRoom.classify_token_result({:error, "timeout"})
      assert {:ok, "token"} = OAuthRoom.classify_token_result({:ok, "token"})
    end
  end
end
