defmodule Tymeslot.Integrations.Calendar.SyncLink.TeardownTest do
  @moduledoc """
  Withdrawing placeholders before the rows that identify them are dropped.

  The ordering is the whole point. A mirror row holds the `target_uid` naming
  the placeholder on the organiser's other calendar; dropping the row first —
  which is exactly what `on_delete: :delete_all` does when a link or an
  integration goes — leaves a busy block on a calendar with nothing owning it
  and nothing that will ever clean it up. So every test here asserts on the
  provider call, not only on the rows: the rows disappearing is not the
  feature, the busy block disappearing is.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :sync_links

  import Mox
  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorSchema
  alias Tymeslot.Integrations.Calendar.SyncLink.Teardown
  alias Tymeslot.Repo

  setup :verify_on_exit!

  setup do
    linked_pair()
  end

  describe "tear_down_link/2" do
    test "withdraws every placeholder from the provider before dropping its row", %{
      user: user,
      target: target,
      link: link
    } do
      test_pid = self()

      first = mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-uid-1")
      second = mirror_for_link(link, source_uid: "src-2", target_uid: "mirror-uid-2")

      expect(Tymeslot.CalendarMock, :delete_event, 2, fn uid, context, _opts ->
        # The row must still be there when the provider is asked: it is what
        # carries the uid being deleted.
        assert Repo.get_by(CalendarSyncMirrorSchema, target_uid: uid),
               "the mapping row must outlive the provider delete"

        send(test_pid, {:deleted, uid, context})
        :ok
      end)

      assert :ok == Teardown.tear_down_link(link, user.id)

      assert_received {:deleted, uid_a, {target_id, user_id}}
      assert_received {:deleted, uid_b, _context}
      assert target_id == target.id
      assert user_id == user.id
      assert Enum.sort([uid_a, uid_b]) == ["mirror-uid-1", "mirror-uid-2"]

      refute Repo.get(CalendarSyncMirrorSchema, first.id)
      refute Repo.get(CalendarSyncMirrorSchema, second.id)
    end

    test "disables the link before any provider call, so nothing re-enqueues mid-teardown", %{
      user: user,
      link: link
    } do
      test_pid = self()

      mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-uid-1")

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        {:ok, reloaded} = CalendarSyncLinkQueries.get(link.id)
        send(test_pid, {:enabled_during_teardown, reloaded.enabled})
        :ok
      end)

      assert :ok == Teardown.tear_down_link(link, user.id)

      assert_received {:enabled_during_teardown, false}
    end

    test "a failed provider delete leaves the row in pending_delete for the sweep", %{
      user: user,
      link: link
    } do
      mirror = mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-uid-1")

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        {:error, :service_unavailable}
      end)

      assert {:error, :service_unavailable} == Teardown.tear_down_link(link, user.id)

      assert %{state: "pending_delete"} = Repo.get(CalendarSyncMirrorSchema, mirror.id)
    end

    test "one failure does not stop the remaining placeholders being withdrawn", %{
      user: user,
      link: link
    } do
      doomed = mirror_for_link(link, source_uid: "src-1", target_uid: "fails")
      fine = mirror_for_link(link, source_uid: "src-2", target_uid: "succeeds")

      expect(Tymeslot.CalendarMock, :delete_event, 2, fn
        "fails", _context, _opts -> {:error, :service_unavailable}
        "succeeds", _context, _opts -> :ok
      end)

      assert {:error, :service_unavailable} == Teardown.tear_down_link(link, user.id)

      assert %{state: "pending_delete"} = Repo.get(CalendarSyncMirrorSchema, doomed.id)
      refute Repo.get(CalendarSyncMirrorSchema, fine.id)
    end

    test "a placeholder already gone from the provider drops its row rather than stalling", %{
      user: user,
      link: link
    } do
      mirror = mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-uid-1")

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        {:error, :not_found}
      end)

      assert :ok == Teardown.tear_down_link(link, user.id)

      refute Repo.get(CalendarSyncMirrorSchema, mirror.id)
    end

    test "a link with no mirrors is torn down without touching the provider", %{
      user: user,
      link: link
    } do
      assert :ok == Teardown.tear_down_link(link, user.id)
      assert CalendarSyncMirrorQueries.list_for_link(link.id) == []
    end
  end

  describe "tear_down_for_integration/2 — as the target" do
    test "withdraws the placeholders living on the integration being disconnected", %{
      user: user,
      target: target,
      link: link
    } do
      mirror = mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-uid-1")

      expect(Tymeslot.CalendarMock, :delete_event, fn "mirror-uid-1",
                                                      {integration_id, _user},
                                                      _opts ->
        assert integration_id == target.id
        :ok
      end)

      assert :ok == Teardown.tear_down_for_integration(target.id, user.id)

      refute Repo.get(CalendarSyncMirrorSchema, mirror.id)
    end
  end

  describe "tear_down_for_integration/2 — as the source" do
    test "withdraws the placeholders this integration caused on other calendars", %{
      user: user,
      source: source,
      target: target,
      link: link
    } do
      mirror = mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-uid-1")

      # Disconnecting the SOURCE leaves nothing to keep the placeholder in step
      # with, so it must go from the target calendar it was written onto.
      expect(Tymeslot.CalendarMock, :delete_event, fn "mirror-uid-1",
                                                      {integration_id, _user},
                                                      _opts ->
        assert integration_id == target.id
        :ok
      end)

      assert :ok == Teardown.tear_down_for_integration(source.id, user.id)

      refute Repo.get(CalendarSyncMirrorSchema, mirror.id)
    end

    test "covers both directions in one pass without double-deleting a shared link",
         %{
           user: user,
           source: source,
           link: link
         } = context do
      # The reverse link makes the source a target as well, so the same
      # integration is named by two links at once.
      reverse = reverse_link(context)

      outbound = mirror_for_link(link, source_uid: "src-1", target_uid: "outbound-uid")
      inbound = mirror_for_link(reverse, source_uid: "src-2", target_uid: "inbound-uid")

      expect(Tymeslot.CalendarMock, :delete_event, 2, fn _uid, _context, _opts -> :ok end)

      assert :ok == Teardown.tear_down_for_integration(source.id, user.id)

      refute Repo.get(CalendarSyncMirrorSchema, outbound.id)
      refute Repo.get(CalendarSyncMirrorSchema, inbound.id)
    end

    test "leaves another organiser's links alone", %{user: user, source: source} do
      stranger = linked_pair()
      theirs = mirror_for_link(stranger.link, source_uid: "src-1", target_uid: "theirs")

      assert :ok == Teardown.tear_down_for_integration(source.id, user.id)

      assert Repo.get(CalendarSyncMirrorSchema, theirs.id)
    end
  end

  describe "tear_down_for_user/1" do
    test "withdraws every placeholder the organiser's links created",
         %{
           user: user,
           link: link
         } = context do
      {_third, other_link} = extra_target_link(context)

      first = mirror_for_link(link, source_uid: "src-1", target_uid: "uid-a")
      second = mirror_for_link(other_link, source_uid: "src-1", target_uid: "uid-b")

      expect(Tymeslot.CalendarMock, :delete_event, 2, fn _uid, _context, _opts -> :ok end)

      assert :ok == Teardown.tear_down_for_user(user.id)

      refute Repo.get(CalendarSyncMirrorSchema, first.id)
      refute Repo.get(CalendarSyncMirrorSchema, second.id)
    end

    test "surfaces the failure when a placeholder cannot be withdrawn", %{
      user: user,
      link: link
    } do
      mirror = mirror_for_link(link, source_uid: "src-1", target_uid: "uid-a")

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        {:error, :service_unavailable}
      end)

      assert {:error, :service_unavailable} == Teardown.tear_down_for_user(user.id)

      assert %{state: "pending_delete"} = Repo.get(CalendarSyncMirrorSchema, mirror.id)
    end

    test "an organiser with no links needs no provider call", %{} do
      user = insert(:user)

      assert :ok == Teardown.tear_down_for_user(user.id)
    end
  end
end
