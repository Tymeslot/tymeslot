defmodule Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueriesTest do
  @moduledoc """
  Data access for mirror mappings: the engine's forward lookup from a link and
  a source UID, and the grid's backward lookup from a set of target
  integrations.

  The backward lookup is the one the grid calls on every render, so it is
  pinned here for shape as well as for content: a MapSet of
  `{integration_id, uid}` pairs, empty for an empty input, never a list the
  caller has to scan.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :sync_links
  @moduletag :queries

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries

  setup do
    link = insert(:calendar_sync_link)
    {:ok, link: link}
  end

  describe "get_by_link_and_source_uid/2" do
    test "finds the mapping for a mirrored source event", %{link: link} do
      mirror = mirror_for_link(link, source_uid: "src-1")

      assert {:ok, found} = CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "src-1")

      assert found.id == mirror.id
      assert found.target_uid == mirror.target_uid
    end

    test "returns not_found for a source event this link has never mirrored", %{link: link} do
      assert CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "never") ==
               {:error, :not_found}
    end

    test "does not return another link's mapping for the same source UID", %{link: link} do
      other_link = insert(:calendar_sync_link)
      mirror_for_link(other_link, source_uid: "src-1")

      assert CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "src-1") ==
               {:error, :not_found}
    end
  end

  describe "mirror_uids_for_integrations/1" do
    test "returns the target integration and UID of each mirror", %{link: link} do
      mirror = mirror_for_link(link)

      assert CalendarSyncMirrorQueries.mirror_uids_for_integrations([link.target_integration_id]) ==
               MapSet.new([{link.target_integration_id, mirror.target_uid}])
    end

    test "is empty for an empty integration list", %{link: link} do
      mirror_for_link(link)

      assert CalendarSyncMirrorQueries.mirror_uids_for_integrations([]) == MapSet.new()
    end

    test "is empty when the integrations hold no mirrors", %{link: link} do
      assert CalendarSyncMirrorQueries.mirror_uids_for_integrations([link.source_integration_id]) ==
               MapSet.new()
    end

    test "does not include mirrors targeting an integration outside the list", %{link: link} do
      other_link = insert(:calendar_sync_link)
      mirror_for_link(other_link)
      mine = mirror_for_link(link)

      assert CalendarSyncMirrorQueries.mirror_uids_for_integrations([link.target_integration_id]) ==
               MapSet.new([{link.target_integration_id, mine.target_uid}])
    end

    test "covers several integrations in one query", %{link: link} do
      other_link = insert(:calendar_sync_link)
      mine = mirror_for_link(link)
      theirs = mirror_for_link(other_link)

      result =
        CalendarSyncMirrorQueries.mirror_uids_for_integrations([
          link.target_integration_id,
          other_link.target_integration_id
        ])

      assert result ==
               MapSet.new([
                 {link.target_integration_id, mine.target_uid},
                 {other_link.target_integration_id, theirs.target_uid}
               ])
    end

    test "includes a pending_delete mirror, which is still on the provider", %{link: link} do
      mirror = mirror_for_link(link, state: "pending_delete")

      assert CalendarSyncMirrorQueries.mirror_uids_for_integrations([link.target_integration_id]) ==
               MapSet.new([{link.target_integration_id, mirror.target_uid}])
    end
  end
end
