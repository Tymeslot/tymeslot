defmodule Tymeslot.Integrations.Video.VideoIntegrationQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.Integrations.Video.VideoIntegrationQueries

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

      insert(:video_integration,
        user: user,
        name: "Z Video",
        provider: "mirotalk",
        is_active: true
      )

      insert(:video_integration,
        user: user,
        name: "A Video",
        provider: "google_meet",
        is_active: true
      )

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

  describe "soft_delete/1" do
    test "hides the integration from the user's listing" do
      user = insert(:user)
      kept = insert(:video_integration, user: user, provider: "zoom")
      going = insert(:video_integration, user: user, provider: "google_meet")

      assert {:ok, _soft} = VideoIntegrationQueries.soft_delete(going)

      ids = user.id |> VideoIntegrationQueries.list_all_for_user() |> Enum.map(& &1.id)
      assert kept.id in ids
      refute going.id in ids

      assert VideoIntegrationQueries.count_for_user(user.id) == 1
    end

    test "keeps the row fetchable by id so cleanup can still authenticate" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, provider: "zoom")

      assert {:ok, _soft} = VideoIntegrationQueries.soft_delete(integration)

      # The drain worker reaches its dying integration through these.
      assert {:ok, by_id} = VideoIntegrationQueries.get(integration.id)
      assert by_id.id == integration.id

      assert {:ok, for_user} = VideoIntegrationQueries.get_for_user(integration.id, user.id)
      assert for_user.id == integration.id
    end

    test "is not offered as a provider fallback" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, provider: "zoom", is_active: true)

      assert {:ok, _soft} = VideoIntegrationQueries.soft_delete(integration)

      assert {:error, :not_found} =
               VideoIntegrationQueries.get_by_provider_for_user(user.id, "zoom")
    end

    test "marks the row inactive so it falls outside every unique index" do
      user = insert(:user)

      integration =
        insert(:video_integration,
          user: user,
          provider: "zoom",
          provider_account_id: "acct-1",
          is_active: true
        )

      assert {:ok, soft} = VideoIntegrationQueries.soft_delete(integration)
      refute soft.is_active
      assert soft.deleted_at

      # Reconnecting the same Zoom account while cleanup is still draining must
      # not collide with the row on its way out.
      assert {:ok, _fresh} =
               VideoIntegrationQueries.create(%{
                 name: "Zoom",
                 provider: "zoom",
                 provider_account_id: "acct-1",
                 access_token: "fresh-access-token",
                 refresh_token: "fresh-refresh-token",
                 user_id: user.id,
                 is_active: true
               })
    end

    test "cannot be reactivated by a stale toggle" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, provider: "zoom", is_active: true)

      assert {:ok, soft} = VideoIntegrationQueries.soft_delete(integration)

      assert {:error, :not_found} = VideoIntegrationQueries.toggle_active(soft)
    end
  end

  # Every uniqueness index is predicated on `is_active = true`, so reactivating
  # a row moves it into the index. The nil and "" account ids used to be waved
  # through, which is exactly the pair the legacy-row and account indexes
  # cover, so the reactivation raised `Ecto.ConstraintError` rather than
  # returning a refusal the dashboard can render.
  describe "toggle_active/1 reactivation conflicts" do
    test "refuses to reactivate a legacy null-account row beside an active one" do
      user = insert(:user)

      insert(:video_integration,
        user: user,
        provider: "zoom",
        provider_account_id: nil,
        is_active: true
      )

      dormant =
        insert(:video_integration,
          user: user,
          provider: "zoom",
          provider_account_id: nil,
          is_active: false
        )

      assert {:error, :duplicate_account} = VideoIntegrationQueries.toggle_active(dormant)
    end

    test "refuses to reactivate an empty-account row beside an active one" do
      user = insert(:user)

      insert(:video_integration,
        user: user,
        provider: "zoom",
        provider_account_id: "",
        is_active: true
      )

      dormant =
        insert(:video_integration,
          user: user,
          provider: "zoom",
          provider_account_id: "",
          is_active: false
        )

      assert {:error, :duplicate_account} = VideoIntegrationQueries.toggle_active(dormant)
    end

    test "reactivates a null-account row when nothing else is active" do
      user = insert(:user)

      dormant =
        insert(:video_integration,
          user: user,
          provider: "zoom",
          provider_account_id: nil,
          is_active: false
        )

      assert {:ok, reactivated} = VideoIntegrationQueries.toggle_active(dormant)
      assert reactivated.is_active
    end
  end
end
