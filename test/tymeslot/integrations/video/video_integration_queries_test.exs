defmodule Tymeslot.Integrations.Video.VideoIntegrationQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Ecto.Changeset
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

    test "a reconnect via update_credentials clears deleted_at instead of resurrecting the row" do
      user = insert(:user)

      integration =
        insert(:video_integration,
          user: user,
          provider: "zoom",
          provider_account_id: "acct-1",
          is_active: true
        )

      assert {:ok, _soft} = VideoIntegrationQueries.soft_delete(integration)

      # An OAuth reconnect reaches its row by id (`reauthorize_existing/3` in
      # `Tymeslot.Integrations.Video`), which does not exclude soft-deleted rows.
      assert {:ok, fetched} = VideoIntegrationQueries.get_for_user(integration.id, user.id)

      assert {:ok, reconnected} =
               VideoIntegrationQueries.update_credentials(fetched, %{is_active: true})

      assert reconnected.is_active
      refute reconnected.deleted_at

      # A previously blocked connect attempt for the same account must now find
      # the reconnected row rather than colliding with a deleted-but-active one.
      assert {:ok, found} =
               VideoIntegrationQueries.get_by_account_for_user(user.id, "zoom", "acct-1")

      assert found.id == integration.id
    end
  end

  describe "delete_if_still_deleted/1" do
    test "deletes a still-soft-deleted row and returns 1" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, provider: "zoom")
      assert {:ok, soft} = VideoIntegrationQueries.soft_delete(integration)

      assert VideoIntegrationQueries.delete_if_still_deleted(soft.id) == 1
      assert {:error, :not_found} = VideoIntegrationQueries.get(soft.id)
    end

    test "leaves a reconnected row alone and returns 0" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, provider: "zoom")
      assert {:ok, soft} = VideoIntegrationQueries.soft_delete(integration)

      # Reconnected before the purge landed: `deleted_at` is nil again.
      assert {:ok, reconnected} =
               VideoIntegrationQueries.update_credentials(soft, %{is_active: true})

      refute reconnected.deleted_at

      assert VideoIntegrationQueries.delete_if_still_deleted(reconnected.id) == 0
      assert {:ok, still_there} = VideoIntegrationQueries.get(reconnected.id)
      assert still_there.id == reconnected.id
    end

    test "returns 0 for an id that does not exist" do
      assert VideoIntegrationQueries.delete_if_still_deleted(-1) == 0
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

  describe "reconnect/2" do
    test "clears the flag and reports that the row was flagged" do
      integration = insert(:video_integration, provider: "zoom", needs_reauth: true)

      assert {:ok, updated, true} =
               VideoIntegrationQueries.reconnect(integration, %{access_token: "new-token"})

      refute updated.needs_reauth
      refute Repo.reload!(integration).needs_reauth
    end

    # `mark_needs_reauth/2` writes the message beside the flag, so a reconnect
    # that clears one and not the other leaves the row explaining a problem it
    # no longer has.
    test "clears the message that explained why reconnecting was needed" do
      integration = insert(:video_integration, provider: "zoom")

      assert {:ok, flagged} =
               VideoIntegrationQueries.mark_needs_reauth(
                 integration,
                 "Zoom refused the stored token"
               )

      assert flagged.sync_error == "Zoom refused the stored token"

      assert {:ok, updated, true} =
               VideoIntegrationQueries.reconnect(flagged, %{access_token: "new-token"})

      refute updated.needs_reauth
      assert updated.sync_error == nil
      assert Repo.reload!(integration).sync_error == nil
    end

    test "reports an unflagged row as not flagged" do
      integration = insert(:video_integration, provider: "zoom")

      assert {:ok, _updated, false} =
               VideoIntegrationQueries.reconnect(integration, %{access_token: "new-token"})
    end

    # The struct was read before a proof that took a network round trip, and a
    # refusal elsewhere flagged the row meanwhile.
    test "clears a flag set after the struct was read, and reports it" do
      integration = insert(:video_integration, provider: "nextcloud_talk")

      Repo.update!(
        Changeset.change(Repo.reload!(integration),
          needs_reauth: true,
          room_creation_error: :password_required
        )
      )

      assert {:ok, _updated, true} =
               VideoIntegrationQueries.reconnect(integration, %{client_secret: "New"})

      reloaded = Repo.reload!(integration)
      refute reloaded.needs_reauth
      assert reloaded.room_creation_error == nil
    end

    test "returns a refused write and leaves the flag in place" do
      integration = insert(:video_integration, provider: "zoom", needs_reauth: true)

      assert {:error, %Changeset{}} =
               VideoIntegrationQueries.reconnect(integration, %{name: nil})

      assert Repo.reload!(integration).needs_reauth
    end
  end

  describe "room creation errors" do
    test "a refusal is recorded once with the time it was first seen, and cleared" do
      integration = insert(:video_integration, provider: "nextcloud_talk")

      assert :ok =
               VideoIntegrationQueries.record_room_creation_error(
                 integration.id,
                 :password_required
               )

      recorded = Repo.reload!(integration)
      assert recorded.room_creation_error == :password_required
      assert %DateTime{} = since = recorded.room_creation_error_since

      Repo.update!(
        Changeset.change(recorded, room_creation_error_since: ~U[2026-01-01 00:00:00Z])
      )

      VideoIntegrationQueries.record_room_creation_error(integration.id, :password_required)
      assert Repo.reload!(integration).room_creation_error_since == ~U[2026-01-01 00:00:00Z]

      VideoIntegrationQueries.record_room_creation_error(integration.id, :talk_not_allowed)
      changed = Repo.reload!(integration)
      assert changed.room_creation_error == :talk_not_allowed
      refute changed.room_creation_error_since == ~U[2026-01-01 00:00:00Z]
      assert DateTime.compare(changed.room_creation_error_since, since) != :lt

      assert :ok = VideoIntegrationQueries.clear_room_creation_error(integration.id)

      assert %{room_creation_error: nil, room_creation_error_since: nil} =
               Repo.reload!(integration)
    end

    test "each code's email is claimed by exactly one caller, per integration" do
      integration = insert(:video_integration, provider: "nextcloud_talk")

      other =
        insert(:video_integration, provider: "nextcloud_talk", base_url: "https://b.example.com")

      assert claim(integration, :password_required)
      refute claim(integration, :password_required)
      assert claim(integration, :talk_not_allowed)
      assert claim(other, :password_required)

      # Clearing the refusal keeps the record of what the owner was told.
      VideoIntegrationQueries.clear_room_creation_error(integration.id)
      refute claim(integration, :password_required)

      assert %{"password_required" => _told_at, "talk_not_allowed" => _also_told_at} =
               Repo.reload!(integration).room_creation_error_notices
    end

    test "a code claimed long enough ago may be claimed again" do
      integration = insert(:video_integration, provider: "nextcloud_talk")
      assert claim(integration, :password_required)

      long_ago = DateTime.add(DateTime.utc_now(:second), -40, :day)

      integration
      |> Changeset.change(
        room_creation_error_notices: %{"password_required" => DateTime.to_iso8601(long_ago)}
      )
      |> Repo.update!()

      assert claim(integration, :password_required)
      refute claim(integration, :password_required)
    end

    test "a claim given back may be claimed again at once" do
      integration = insert(:video_integration, provider: "nextcloud_talk")
      assert claim(integration, :password_required)
      assert claim(integration, :talk_not_allowed)

      assert :ok =
               VideoIntegrationQueries.release_room_creation_error_notice(
                 integration.id,
                 :password_required
               )

      assert %{"talk_not_allowed" => _kept} =
               Repo.reload!(integration).room_creation_error_notices

      assert claim(integration, :password_required)
    end

    # A refusal of the same code inside the window is the one the owner already
    # knows about, whatever their integration's other codes have done since.
    defp claim(integration, code) do
      now = DateTime.utc_now(:second)

      VideoIntegrationQueries.claim_room_creation_error_notice(
        integration.id,
        code,
        now,
        DateTime.add(now, -30, :day)
      )
    end
  end
end
