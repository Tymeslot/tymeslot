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

  describe "subscriber isolation" do
    # Composition guard: the broadcaster must not be affected by one
    # subscriber misbehaving, and surviving subscribers must still
    # receive their copy of the message. Phoenix.PubSub's fire-and-
    # forget `send/2` delivery is what makes this possible — if
    # SyncBroadcast ever changed to a synchronous/acking model, a
    # crashing or dead subscriber would block or error the broadcaster
    # and this test would catch it.
    test "a dead subscriber does not prevent delivery to live subscribers" do
      user = insert(:user)
      topic = "calendar_events:#{user.id}"
      test_pid = self()
      ref = make_ref()

      # Alive subscriber — forwards its received message to the test.
      alive_pid =
        spawn(fn ->
          Phoenix.PubSub.subscribe(Tymeslot.PubSub, topic)
          send(test_pid, {ref, :alive_subscribed})

          receive do
            msg -> send(test_pid, {ref, :alive_received, msg})
          after
            2_000 -> send(test_pid, {ref, :alive_timeout})
          end
        end)

      # Short-lived subscriber — subscribes, then exits. pg's cleanup
      # callback removes the dead pid from the group asynchronously; we
      # monitor it so we can wait for it to fully leave before firing
      # the broadcast.
      {short_pid, short_ref} =
        spawn_monitor(fn ->
          Phoenix.PubSub.subscribe(Tymeslot.PubSub, topic)
          send(test_pid, {ref, :short_subscribed})
          :ok
        end)

      assert_receive {^ref, :alive_subscribed}, 1_000
      assert_receive {^ref, :short_subscribed}, 1_000
      assert_receive {:DOWN, ^short_ref, :process, ^short_pid, _}, 1_000

      # The broadcaster's public contract is `:ok` regardless of
      # subscriber health — verifies it never bubbles a subscriber
      # failure up to the caller.
      assert :ok = SyncBroadcast.broadcast_cache_update(user.id, ["uid-x"])

      assert_receive {^ref, :alive_received,
                      {:calendar_events_updated, received_user_id, ["uid-x"]}},
                     1_000

      assert received_user_id == user.id

      # Tidy up the surviving process.
      Process.exit(alive_pid, :kill)
    end

    test "a subscriber that raises on receive does not disrupt other subscribers" do
      user = insert(:user)
      topic = "calendar_events:#{user.id}"
      test_pid = self()
      ref = make_ref()

      # Subscriber that crashes the instant it processes the message.
      # It still receives its copy from PubSub — the crash happens
      # after delivery, inside the subscriber's own process.
      {crash_pid, crash_ref} =
        spawn_monitor(fn ->
          Phoenix.PubSub.subscribe(Tymeslot.PubSub, topic)
          send(test_pid, {ref, :crash_subscribed})

          receive do
            _msg -> raise "subscriber boom"
          after
            2_000 -> :ok
          end
        end)

      # Surviving subscriber — this one must still receive the message
      # regardless of the other subscriber's fate.
      alive_pid =
        spawn(fn ->
          Phoenix.PubSub.subscribe(Tymeslot.PubSub, topic)
          send(test_pid, {ref, :alive_subscribed})

          receive do
            msg -> send(test_pid, {ref, :alive_received, msg})
          after
            2_000 -> send(test_pid, {ref, :alive_timeout})
          end
        end)

      assert_receive {^ref, :crash_subscribed}, 1_000
      assert_receive {^ref, :alive_subscribed}, 1_000

      assert :ok = SyncBroadcast.broadcast_sync_complete(user.id, 42)

      # The crashing subscriber does its thing (caught by the
      # `:capture_log` tag on the test or just the default logger).
      assert_receive {:DOWN, ^crash_ref, :process, ^crash_pid, {%RuntimeError{}, _stack}},
                     1_000

      # The surviving subscriber receives its copy of the broadcast —
      # proof that one subscriber's crash does not block delivery to
      # the rest of the pg group.
      assert_receive {^ref, :alive_received, {:calendar_sync_complete, received_user_id, 42}},
                     1_000

      assert received_user_id == user.id

      Process.exit(alive_pid, :kill)
    end
  end
end
