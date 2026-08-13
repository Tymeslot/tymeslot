defmodule Tymeslot.Integrations.Calendar.SyncLink.ConflictHistoryTest do
  @moduledoc """
  The read side of the conflict audit, and the ownership check that guards it.

  `CalendarSyncConflictQueries.list_for_link/2` takes an integer and answers for
  whatever link carries it, so a LiveView reaching it directly would hand the
  browser another organiser's history — which names their event UIDs and the
  times their calendars diverged — for the price of guessing an id. The check
  belongs here, and the negative case is asserted as `{:error, :not_found}`
  rather than `:forbidden` so a forged id cannot be used to probe which ids
  exist.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :sync_links

  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.SyncLink.ConflictHistory

  setup do
    linked_pair()
  end

  describe "for_link/3" do
    test "returns the link's history newest first", %{user: user, link: link} do
      now = DateTime.utc_now(:microsecond)

      insert(:calendar_sync_conflict,
        sync_link_id: link.id,
        source_uid: "older",
        occurred_at: DateTime.add(now, -3600, :second)
      )

      insert(:calendar_sync_conflict,
        sync_link_id: link.id,
        source_uid: "newer",
        occurred_at: now
      )

      assert {:ok, conflicts} = ConflictHistory.for_link(user.id, link.id)
      assert Enum.map(conflicts, & &1.source_uid) == ["newer", "older"]
    end

    test "refuses a link belonging to another organiser", %{link: link} do
      stranger = insert(:user)

      insert(:calendar_sync_conflict, sync_link_id: link.id)

      assert {:error, :not_found} == ConflictHistory.for_link(stranger.id, link.id)
    end

    test "refuses a link that does not exist, and an id that is not one", %{
      user: user,
      link: link
    } do
      assert {:error, :not_found} == ConflictHistory.for_link(user.id, link.id + 10_000)
      assert {:error, :not_found} == ConflictHistory.for_link(user.id, "not-an-id")
      assert {:error, :not_found} == ConflictHistory.for_link(user.id, nil)
    end

    test "caps the window it returns", %{user: user, link: link} do
      for index <- 1..6 do
        insert(:calendar_sync_conflict, sync_link_id: link.id, source_uid: "uid-#{index}")
      end

      assert {:ok, conflicts} = ConflictHistory.for_link(user.id, link.id, limit: 2)
      assert length(conflicts) == 2
    end
  end

  describe "recent_for_user/2" do
    test "keys one organiser's history by link", ctx do
      %{user: user, link: link} = ctx
      {_other_target, other_link} = extra_target_link(ctx)

      insert(:calendar_sync_conflict, sync_link_id: link.id, source_uid: "first")
      insert(:calendar_sync_conflict, sync_link_id: other_link.id, source_uid: "second")

      history = ConflictHistory.recent_for_user(user.id)

      assert Enum.map(history[link.id], & &1.source_uid) == ["first"]
      assert Enum.map(history[other_link.id], & &1.source_uid) == ["second"]
    end

    test "never includes another organiser's links", %{user: user} do
      stranger_link = insert(:calendar_sync_link)
      insert(:calendar_sync_conflict, sync_link_id: stranger_link.id)

      assert ConflictHistory.recent_for_user(user.id) == %{}
    end

    test "omits a link that has never conflicted", %{user: user, link: link} do
      assert ConflictHistory.recent_for_user(user.id) == %{}
      refute Map.has_key?(ConflictHistory.recent_for_user(user.id), link.id)
    end
  end
end
