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

  describe "list_for_links/2" do
    test "caps each link's history independently", %{link: link} do
      other_link = insert(:calendar_sync_link)

      for index <- 1..4 do
        insert(:calendar_sync_conflict, sync_link_id: link.id, source_uid: "mine-#{index}")

        insert(:calendar_sync_conflict,
          sync_link_id: other_link.id,
          source_uid: "theirs-#{index}"
        )
      end

      histories = CalendarSyncConflictQueries.list_for_links([link.id, other_link.id], limit: 2)

      # Per link, not overall: two links asking for two each get two each. An
      # overall LIMIT would answer four rows in total and could hand them all to
      # one link, leaving the other's section empty on a dashboard that has
      # conflicts to show.
      assert length(Map.fetch!(histories, link.id)) == 2
      assert length(Map.fetch!(histories, other_link.id)) == 2
    end

    test "keeps each link's newest rows", %{link: link} do
      now = DateTime.utc_now(:microsecond)

      for {uid, offset} <- [{"oldest", -7200}, {"middle", -3600}, {"newest", 0}] do
        insert(:calendar_sync_conflict,
          sync_link_id: link.id,
          source_uid: uid,
          occurred_at: DateTime.add(now, offset, :second)
        )
      end

      histories = CalendarSyncConflictQueries.list_for_links([link.id], limit: 2)

      assert Enum.map(Map.fetch!(histories, link.id), & &1.source_uid) == ["newest", "middle"]
    end

    test "omits a link with no history", %{link: link} do
      quiet_link = insert(:calendar_sync_link)
      insert(:calendar_sync_conflict, sync_link_id: link.id)

      histories = CalendarSyncConflictQueries.list_for_links([link.id, quiet_link.id])

      assert Map.has_key?(histories, link.id)
      refute Map.has_key?(histories, quiet_link.id)
    end

    # The cap is what bounds the read, so it has to bound what Postgres returns
    # rather than what the caller keeps. Applied with `Enum.take` after an
    # unbounded `Repo.all()`, a 90-day retention window means every conflict row
    # for every link is loaded and sorted on each dashboard render, and the
    # assertions above all still pass. Counting the rows the adapter actually
    # handed back is the only thing that catches it.
    test "does not load the rows it is going to discard", %{link: link} do
      for index <- 1..20 do
        insert(:calendar_sync_conflict, sync_link_id: link.id, source_uid: "src-#{index}")
      end

      test_pid = self()
      handler_id = "conflict-limit-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:tymeslot, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          case metadata do
            %{source: "calendar_sync_conflicts", result: {:ok, %{num_rows: rows}}} ->
              send(test_pid, {:rows_read, rows})

            _other_query ->
              :ok
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      histories = CalendarSyncConflictQueries.list_for_links([link.id], limit: 3)

      assert length(Map.fetch!(histories, link.id)) == 3

      assert_received {:rows_read, rows_read}
      assert rows_read == 3
    end
  end
end
