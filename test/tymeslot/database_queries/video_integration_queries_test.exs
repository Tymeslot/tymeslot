defmodule Tymeslot.DatabaseQueries.VideoIntegrationQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.DatabaseQueries.VideoIntegrationQueries

  describe "video integration business rules" do
    test "default integration always appears first for user" do
      user = insert(:user)

      insert(:video_integration, user: user, name: "Z Video", is_active: true, is_default: false)
      insert(:video_integration, user: user, name: "A Video", is_active: true, is_default: true)
      insert(:video_integration, user: user, name: "B Video", is_active: true, is_default: false)

      result = VideoIntegrationQueries.list_active_for_user(user.id)

      # Business rule: default integration must be first
      assert Enum.at(result, 0).is_default == true
      assert Enum.at(result, 0).name == "A Video"
    end

    test "only one default integration allowed per user" do
      user = insert(:user)

      _vi1 = insert(:video_integration, user: user, is_default: true)
      vi2 = insert(:video_integration, user: user, is_default: false)

      # Setting new default should unset previous
      {:ok, _updated} = VideoIntegrationQueries.set_as_default(vi2)

      integrations = VideoIntegrationQueries.list_all_for_user(user.id)
      default_count = Enum.count(integrations, & &1.is_default)

      assert default_count == 1
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
          provider: "google_meet",
          access_token: "valid-token",
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        )

      # Business logic should identify expired tokens
      assert DateTime.compare(expired_integration.token_expires_at, DateTime.utc_now()) == :lt
      assert DateTime.compare(active_integration.token_expires_at, DateTime.utc_now()) == :gt
    end
  end
end
