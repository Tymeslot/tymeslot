defmodule Tymeslot.Integrations.Calendar.SyncBroadcastTest do
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.SyncBroadcast

  defp subscribe(user_id) do
    Phoenix.PubSub.subscribe(Tymeslot.PubSub, "calendar_events:#{user_id}")
  end

  describe "broadcast_cache_update/2" do
    test "broadcasts calendar_events_updated to subscribers" do
      user = insert(:user)
      subscribe(user.id)

      uids = ["uid-1", "uid-2"]
      assert :ok = SyncBroadcast.broadcast_cache_update(user.id, uids)

      assert_receive {:calendar_events_updated, user_id, ^uids}
      assert user_id == user.id
    end
  end

  describe "broadcast_sync_complete/2" do
    test "broadcasts calendar_sync_complete to subscribers" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)
      subscribe(user.id)

      assert :ok = SyncBroadcast.broadcast_sync_complete(user.id, integration.id)

      assert_receive {:calendar_sync_complete, user_id, integration_id}
      assert user_id == user.id
      assert integration_id == integration.id
    end
  end
end
