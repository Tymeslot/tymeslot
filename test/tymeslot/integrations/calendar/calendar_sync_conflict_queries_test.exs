defmodule Tymeslot.Integrations.Calendar.CalendarSyncConflictQueriesTest do
  @moduledoc """
  Data access for the conflict audit: appending a resolution, and reading one
  link's history back newest first, which is the order the dashboard shows and
  the only order in which a divergence is useful to an organiser.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :sync_links
  @moduletag :queries

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarSyncConflictQueries

  setup do
    link = insert(:calendar_sync_link)
    {:ok, link: link}
  end

  describe "append/1" do
    test "records a resolution", %{link: link} do
      assert {:ok, conflict} =
               CalendarSyncConflictQueries.append(%{
                 sync_link_id: link.id,
                 source_uid: "src-1",
                 kind: "both_changed",
                 resolution: "source_won"
               })

      assert conflict.kind == "both_changed"
      assert conflict.resolution == "source_won"
      assert conflict.occurred_at
    end

    test "stores the detail map the branch had in hand", %{link: link} do
      assert {:ok, conflict} =
               CalendarSyncConflictQueries.append(%{
                 sync_link_id: link.id,
                 source_uid: "src-1",
                 kind: "write_failed",
                 resolution: "skipped",
                 detail: %{"error" => "412 precondition failed"}
               })

      assert conflict.detail == %{"error" => "412 precondition failed"}
    end

    test "returns the changeset for a kind the engine never produces", %{link: link} do
      assert {:error, changeset} =
               CalendarSyncConflictQueries.append(%{
                 sync_link_id: link.id,
                 source_uid: "src-1",
                 kind: "invented",
                 resolution: "source_won"
               })

      assert "is invalid" in errors_on(changeset).kind
    end
  end

  describe "list_for_link/2" do
    test "returns the link's history newest first", %{link: link} do
      now = DateTime.utc_now(:microsecond)

      insert(:calendar_sync_conflict,
        sync_link_id: link.id,
        source_uid: "old",
        occurred_at: DateTime.add(now, -3600, :second)
      )

      insert(:calendar_sync_conflict, sync_link_id: link.id, source_uid: "new", occurred_at: now)

      assert link.id |> CalendarSyncConflictQueries.list_for_link() |> Enum.map(& &1.source_uid) ==
               ["new", "old"]
    end

    test "returns nothing for a link that has never conflicted", %{link: link} do
      assert CalendarSyncConflictQueries.list_for_link(link.id) == []
    end

    test "does not leak another link's history", %{link: link} do
      other_link = insert(:calendar_sync_link)
      insert(:calendar_sync_conflict, sync_link_id: other_link.id)

      assert CalendarSyncConflictQueries.list_for_link(link.id) == []
    end

    test "caps the history at the requested limit", %{link: link} do
      for index <- 1..5 do
        insert(:calendar_sync_conflict, sync_link_id: link.id, source_uid: "src-#{index}")
      end

      assert length(CalendarSyncConflictQueries.list_for_link(link.id, limit: 2)) == 2
    end
  end
end
