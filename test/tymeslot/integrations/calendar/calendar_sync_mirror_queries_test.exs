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

      set = CalendarSyncMirrorQueries.mirror_uids_for_integrations([link.target_integration_id])

      assert MapSet.member?(set, {link.target_integration_id, mirror.target_uid})
      assert MapSet.member?(set, {link.target_integration_id, mirror.target_provider_event_id})
    end

    # The last gap between the id as *recorded* and the uid as *cached*. The
    # write answers with Google's bare event id (`convert_event/1` reads the
    # response's `"id"`), while the cache is filled by the normaliser, which
    # prefers `"iCalUID"` — the same id with `@google.com` appended. Storing
    # only the bare form means the recorded id never equals the cached uid, so
    # the placeholder still reads as an ordinary event even once the right id
    # is recorded.
    test "carries the suffixed form the cache actually holds for a Google placeholder", %{
      link: link
    } do
      mirror_for_link(link, target_provider_event_id: "google-assigned-id")

      set = CalendarSyncMirrorQueries.mirror_uids_for_integrations([link.target_integration_id])

      assert MapSet.member?(set, {link.target_integration_id, "google-assigned-id@google.com"}),
             "the cache stores Google's iCalUID, so the set must contain that form too"
    end

    test "does not double-suffix an identifier that already carries the domain", %{link: link} do
      mirror_for_link(link, target_provider_event_id: "already-there@google.com")

      set = CalendarSyncMirrorQueries.mirror_uids_for_integrations([link.target_integration_id])

      assert MapSet.member?(set, {link.target_integration_id, "already-there@google.com"})

      refute MapSet.member?(
               set,
               {link.target_integration_id, "already-there@google.com@google.com"}
             )
    end

    test "is empty for an empty integration list", %{link: link} do
      mirror_for_link(link)

      assert CalendarSyncMirrorQueries.mirror_uids_for_integrations([]) == MapSet.new()
    end

    test "is empty when the integrations hold no mirrors", %{link: link} do
      assert CalendarSyncMirrorQueries.mirror_uids_for_integrations([link.source_integration_id]) ==
               MapSet.new()
    end

    # The set exists to answer one question — "is this cached event a
    # placeholder we wrote?" — and it is asked with the UID the *provider*
    # reports, not the one we asked for. Google does not keep ours: a create
    # sends `id`, and Google answers with an iCalUID of its own making,
    # `{id}@google.com`. The next inbound sync caches that, so the cached UID
    # never equals the `target_uid` we stored and the placeholder reads as an
    # ordinary event.
    #
    # In production every one of 317 cached placeholders was unrecognisable
    # this way, which disabled loop prevention entirely: each placeholder
    # became a source and was mirrored back, so one event grew a second and
    # third "Busy" on the same calendar.
    #
    # So the set carries the provider's id as well as ours. Both are matched
    # because the CalDAV family does keep the UID it is given.
    test "also carries the id the provider gave the placeholder", %{link: link} do
      mirror = mirror_for_link(link, target_provider_event_id: "google-assigned-id")

      set = CalendarSyncMirrorQueries.mirror_uids_for_integrations([link.target_integration_id])

      assert MapSet.member?(set, {link.target_integration_id, mirror.target_uid}),
             "the uid we asked for must still match, for providers that keep it"

      assert MapSet.member?(set, {link.target_integration_id, "google-assigned-id"}),
             "a placeholder Google renamed is invisible to loop prevention without this"
    end

    test "omits a provider id that was never recorded", %{link: link} do
      # A mirror whose write failed has no provider id yet. Adding `nil` to the
      # set would make every event with no uid look like a placeholder.
      mirror_for_link(link, target_provider_event_id: nil)

      set = CalendarSyncMirrorQueries.mirror_uids_for_integrations([link.target_integration_id])

      refute Enum.any?(set, fn {_integration_id, uid} -> is_nil(uid) end)
    end

    test "does not include mirrors targeting an integration outside the list", %{link: link} do
      other_link = insert(:calendar_sync_link)
      theirs = mirror_for_link(other_link)
      mine = mirror_for_link(link)

      set = CalendarSyncMirrorQueries.mirror_uids_for_integrations([link.target_integration_id])

      assert MapSet.member?(set, {link.target_integration_id, mine.target_uid})
      assert MapSet.member?(set, {link.target_integration_id, mine.target_provider_event_id})

      # The exclusion is the point of the test, so it is asserted on the
      # integration id rather than on the set's exact contents — which also
      # carries the suffixed variants of every identifier.
      refute Enum.any?(set, fn {integration_id, _uid} ->
               integration_id == other_link.target_integration_id
             end)

      refute MapSet.member?(set, {link.target_integration_id, theirs.target_uid})
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

      assert MapSet.member?(result, {link.target_integration_id, mine.target_uid})
      assert MapSet.member?(result, {link.target_integration_id, mine.target_provider_event_id})
      assert MapSet.member?(result, {other_link.target_integration_id, theirs.target_uid})

      assert MapSet.member?(
               result,
               {other_link.target_integration_id, theirs.target_provider_event_id}
             )
    end

    test "includes a pending_delete mirror, which is still on the provider", %{link: link} do
      mirror = mirror_for_link(link, state: "pending_delete")

      set = CalendarSyncMirrorQueries.mirror_uids_for_integrations([link.target_integration_id])

      assert MapSet.member?(set, {link.target_integration_id, mirror.target_uid})
      assert MapSet.member?(set, {link.target_integration_id, mirror.target_provider_event_id})
    end
  end

  describe "create/1" do
    test "records a placeholder the engine has written", %{link: link} do
      assert {:ok, mirror} =
               CalendarSyncMirrorQueries.create(%{
                 sync_link_id: link.id,
                 source_uid: "src-1",
                 target_integration_id: link.target_integration_id,
                 target_uid: "tymeslot-mirror-1",
                 target_provider_event_id: "pid-1",
                 state: "active"
               })

      assert mirror.state == "active"

      assert {:ok, _found} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "src-1")
    end

    # Orphan compensation depends on this: the engine has to see the failure to
    # know it must delete the provider event it just created.
    test "returns the changeset rather than raising when the row cannot be written" do
      assert {:error, %Ecto.Changeset{}} =
               CalendarSyncMirrorQueries.create(%{source_uid: "src-1"})
    end
  end

  describe "update/2" do
    test "moves a mirror's state", %{link: link} do
      mirror = mirror_for_link(link)

      assert {:ok, updated} =
               CalendarSyncMirrorQueries.update(mirror, %{state: "pending_delete"})

      assert updated.state == "pending_delete"
    end

    test "rejects a state outside the vocabulary", %{link: link} do
      mirror = mirror_for_link(link)

      assert {:error, changeset} = CalendarSyncMirrorQueries.update(mirror, %{state: "vanished"})
      assert %{state: [_message]} = errors_on(changeset)
    end
  end

  describe "list_for_link/1" do
    test "returns every mapping the link holds, in any state", %{link: link} do
      active = mirror_for_link(link, source_uid: "src-active", state: "active")
      pending = mirror_for_link(link, source_uid: "src-pending", state: "pending_delete")
      failed = mirror_for_link(link, source_uid: "src-failed", state: "failed")

      ids = MapSet.new(CalendarSyncMirrorQueries.list_for_link(link.id), & &1.id)

      assert ids == MapSet.new([active.id, pending.id, failed.id])
    end

    test "does not return another link's mappings", %{link: link} do
      other = insert(:calendar_sync_link)
      mirror_for_link(other, source_uid: "elsewhere")
      mine = mirror_for_link(link, source_uid: "mine")

      assert Enum.map(CalendarSyncMirrorQueries.list_for_link(link.id), & &1.id) == [mine.id]
    end

    test "returns an empty list for a link with no mappings", %{link: link} do
      assert CalendarSyncMirrorQueries.list_for_link(link.id) == []
    end
  end

  describe "delete/1" do
    test "drops the mapping once the provider has confirmed the placeholder is gone", %{
      link: link
    } do
      mirror = mirror_for_link(link, source_uid: "src-1")

      assert {:ok, _deleted} = CalendarSyncMirrorQueries.delete(mirror)

      assert {:error, :not_found} ==
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "src-1")
    end
  end
end
