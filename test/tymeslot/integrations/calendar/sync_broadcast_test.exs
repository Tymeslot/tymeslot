defmodule Tymeslot.Integrations.Calendar.SyncBroadcastTest do
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalendarEventCacheSchema
  alias Tymeslot.Integrations.Calendar.SyncBroadcast

  defp subscribe(user_id) do
    Phoenix.PubSub.subscribe(Tymeslot.PubSub, "calendar_events:#{user_id}")
  end

  defp build_event_attrs(integration) do
    now = DateTime.utc_now(:second)

    %{
      uid: "test-event-#{System.unique_integer([:positive])}",
      calendar_integration_id: integration.id,
      start_at: now,
      end_at: DateTime.add(now, 3600, :second),
      title: "Test Event"
    }
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

  describe "upsert_and_broadcast/2" do
    test "upserts event to cache and broadcasts update" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)
      attrs = build_event_attrs(integration)
      subscribe(user.id)

      assert :ok = SyncBroadcast.upsert_and_broadcast(user.id, attrs)

      # Verify event in DB
      assert [event] =
               Repo.all(
                 from(e in CalendarEventCacheSchema,
                   where:
                     e.calendar_integration_id == ^integration.id and
                       e.uid == ^attrs.uid
                 )
               )

      assert event.title == "Test Event"

      # Verify broadcast
      assert_receive {:calendar_events_updated, _, [uid]}
      assert uid == attrs.uid
    end

    test "raises when upsert hits a constraint violation" do
      user = insert(:user)

      # Missing calendar_integration_id — will fail foreign key
      attrs = %{
        uid: "orphan-event",
        calendar_integration_id: -1,
        start_at: DateTime.utc_now(:second),
        end_at: DateTime.add(DateTime.utc_now(:second), 3600, :second),
        title: "Bad Event"
      }

      assert_raise Postgrex.Error, fn ->
        SyncBroadcast.upsert_and_broadcast(user.id, attrs)
      end
    end
  end

  describe "process_cached_event/4" do
    test "calls on_success callback when upsert succeeds" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)
      attrs = build_event_attrs(integration)
      test_pid = self()

      on_success = fn -> send(test_pid, :callback_called) end

      # Return value is propagated from on_success callback
      SyncBroadcast.process_cached_event(
        user.id,
        attrs,
        [provider: "caldav"],
        on_success
      )

      assert_receive :callback_called
    end

    test "does not call on_success when upsert fails" do
      user = insert(:user)
      test_pid = self()
      on_success = fn -> send(test_pid, :callback_called) end

      attrs = %{
        uid: "orphan-event",
        calendar_integration_id: -1,
        start_at: DateTime.utc_now(:second),
        end_at: DateTime.add(DateTime.utc_now(:second), 3600, :second),
        title: "Bad Event"
      }

      assert_raise Postgrex.Error, fn ->
        SyncBroadcast.process_cached_event(
          user.id,
          attrs,
          [provider: "caldav"],
          on_success
        )
      end

      refute_receive :callback_called
    end
  end
end
