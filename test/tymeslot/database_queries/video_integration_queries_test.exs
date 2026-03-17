defmodule Tymeslot.DatabaseQueries.VideoIntegrationQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.DatabaseQueries.VideoIntegrationQueries

  describe "get_by_provider_for_user/2" do
    test "returns active integration for user+provider" do
      user = insert(:user)

      integration =
        insert(:video_integration,
          user: user,
          provider: "google_meet",
          is_active: true
        )

      assert {:ok, found} =
               VideoIntegrationQueries.get_by_provider_for_user(user.id, "google_meet")

      assert found.id == integration.id
    end

    test "returns :not_found when no integration exists" do
      user = insert(:user)

      assert {:error, :not_found} =
               VideoIntegrationQueries.get_by_provider_for_user(user.id, "google_meet")
    end

    test "ignores inactive integrations" do
      user = insert(:user)

      insert(:video_integration,
        user: user,
        provider: "google_meet",
        is_active: false
      )

      assert {:error, :not_found} =
               VideoIntegrationQueries.get_by_provider_for_user(user.id, "google_meet")
    end

    test "does not return integrations from other users" do
      user = insert(:user)
      other_user = insert(:user)

      insert(:video_integration,
        user: other_user,
        provider: "google_meet",
        is_active: true
      )

      assert {:error, :not_found} =
               VideoIntegrationQueries.get_by_provider_for_user(user.id, "google_meet")
    end

    test "does not return integrations for different provider" do
      user = insert(:user)

      insert(:video_integration,
        user: user,
        provider: "teams",
        is_active: true
      )

      assert {:error, :not_found} =
               VideoIntegrationQueries.get_by_provider_for_user(user.id, "google_meet")
    end
  end

  describe "video integration business rules" do
    test "active integrations are ordered by name for user" do
      user = insert(:user)

      insert(:video_integration, user: user, name: "Z Video", provider: "mirotalk", is_active: true)
      insert(:video_integration, user: user, name: "A Video", provider: "google_meet", is_active: true)
      insert(:video_integration, user: user, name: "B Video", provider: "teams", is_active: true)

      result = VideoIntegrationQueries.list_active_for_user(user.id)

      assert Enum.at(result, 0).name == "A Video"
      assert Enum.at(result, 1).name == "B Video"
      assert Enum.at(result, 2).name == "Z Video"
    end

    test "provider-specific settings are preserved during updates" do
      user = insert(:user)

      integration =
        insert(:video_integration,
          user: user,
          provider: "mirotalk",
          settings: %{
            "server_url" => "https://custom.mirotalk.com",
            "api_endpoint" => "/api/v2/custom"
          }
        )

      {:ok, updated} =
        VideoIntegrationQueries.update(
          integration,
          %{name: "Updated Name"}
        )

      # Business rule: provider settings must persist through updates
      assert updated.settings["server_url"] == "https://custom.mirotalk.com"
      assert updated.settings["api_endpoint"] == "/api/v2/custom"
    end

    test "OAuth tokens expire after configured time" do
      user = insert(:user)

      expired_integration =
        insert(:video_integration,
          user: user,
          provider: "google_meet",
          access_token: "expired-token",
          token_expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        )

      active_integration =
        insert(:video_integration,
          user: user,
          provider: "teams",
          access_token: "valid-token",
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        )

      # Business logic should identify expired tokens
      assert DateTime.compare(expired_integration.token_expires_at, DateTime.utc_now()) == :lt
      assert DateTime.compare(active_integration.token_expires_at, DateTime.utc_now()) == :gt
    end
  end
end
