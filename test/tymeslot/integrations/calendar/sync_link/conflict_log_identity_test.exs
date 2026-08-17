defmodule Tymeslot.Integrations.Calendar.SyncLink.ConflictLogIdentityTest do
  @moduledoc """
  That the conflict log finds the placeholder it is reasoning about, and that the
  two etags it compares are in the same form.

  `EngineConflictTest` and `EngineEtagBaselineTest` both cache the placeholder
  under `Engine.target_uid_for/2` — the UID the write was *addressed to*. For the
  CalDAV family that is right, because it keeps the UID it is handed. For Google
  it is an identity the cache never holds: a create sends `id`, Google mints its
  own `iCalUID` as `{id}@google.com`, and `EventNormaliser.build_calendar_event/2`
  caches `raw["iCalUID"] || raw["id"]` (`event_normaliser.ex:65`). So every one of
  those tests exercised a lookup that succeeds only for a provider whose write
  response the same tests do not use.

  Measured on a live installation: 105 active mirror rows, none of them found by
  `target_uid`, all 105 found by `target_provider_event_id <> "@google.com"`.
  Every etag-based kind was therefore dead for a Google target, while the suite
  was green.

  The second half is what that deadness was hiding. `WriteEtag.extract/1` strips
  the quotes from the write response's entity tag before it reaches the mirror
  row, and `EventNormaliser` stores `raw["etag"]` into the cache with its quotes
  intact (`event_normaliser.ex:82`). Bare against quoted can never compare equal,
  so the moment the lookup starts succeeding every untouched placeholder reads as
  a stranger's edit — one conflict row per mirror per sweep. The two defects have
  to be fixed together, and these tests are written so that fixing either alone
  leaves the other's failure visible.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :sync_links

  import Mox
  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarSyncConflictQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries
  alias Tymeslot.Integrations.Calendar.SyncLink.Engine

  setup :verify_on_exit!

  setup do
    linked_pair()
  end

  @before_sync ~U[2026-07-01 09:00:00.000000Z]

  # The bare event id Google filed the placeholder under, in the shape the live
  # rows carry it: `target_provider_event_id` on the mirror, and the stem of the
  # `@google.com` iCalUID in the cache.
  @google_event_id "k7crcuk3nrsaagh95hf2kb7b4sq2554u"

  defp source_event(source, attrs) do
    CalendarEvent.new!(
      Map.merge(
        %{
          uid: "source-uid-1",
          calendar_integration_id: source.id,
          provider: :google,
          provider_calendar_id: "primary",
          provider_event_id: "source-pid-1",
          summary: "Board meeting",
          all_day: false,
          start_at: ~U[2026-07-03 09:00:00Z],
          end_at: ~U[2026-07-03 10:00:00Z],
          synced_at: ~U[2026-07-01 00:00:00Z]
        },
        attrs
      )
    )
  end

  defp mirror(link),
    do: CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")

  defp conflicts(link), do: CalendarSyncConflictQueries.list_for_link(link.id)

  defp target_uid(link), do: Engine.target_uid_for(link.id, "source-uid-1")

  # The mirror row as it exists on the live installation: the UID we asked for,
  # and beside it the id Google answered with, which is a different string.
  defp google_mirror(link, attrs) do
    mirror_for_link(
      link,
      Keyword.merge(
        [
          source_uid: "source-uid-1",
          target_uid: target_uid(link),
          target_provider_event_id: @google_event_id,
          target_etag: "3573898397004446",
          last_synced_at: ~U[2026-07-01 12:00:00.000000Z]
        ],
        attrs
      )
    )
  end

  describe "finding the placeholder a Google target cached" do
    test "reads the cache row filed under the provider's iCalUID, not the UID we asked for",
         ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      google_mirror(link, source_updated_at: @before_sync)

      # Cached exactly as the live install holds it — under the suffixed id, with
      # no row at all under `target_uid`.
      google_cached_placeholder(target, @google_event_id,
        etag: "\"3555778156955438\"",
        provider_updated_at: ~U[2026-07-01 15:00:00.000000Z]
      )

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context -> :ok end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @before_sync}),
                 user.id
               )

      assert [conflict] = conflicts(link)
      assert conflict.kind == "mirror_edited"
      assert conflict.resolution == "source_won"
      assert conflict.detail["target_etag_written"] == "3573898397004446"
      assert conflict.detail["target_etag_observed"] == "\"3555778156955438\""
    end

    test "still reads the CalDAV placeholder, which is cached under the UID we asked for",
         ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      # The other family, and the reason the identity has to be *expanded* rather
      # than swapped: a CalDAV server stores the UID it was handed, so the cache
      # row is under `target_uid` and there is no suffixed form anywhere.
      google_mirror(link,
        source_updated_at: @before_sync,
        target_provider_event_id: target_uid(link)
      )

      insert(:provider_calendar_event,
        calendar_integration: target,
        uid: target_uid(link),
        summary: "Busy",
        provider: "caldav",
        provider_event_id: target_uid(link),
        etag: "3555778156955438",
        provider_updated_at: ~U[2026-07-01 15:00:00.000000Z]
      )

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context -> :ok end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @before_sync}),
                 user.id
               )

      assert [conflict] = conflicts(link)
      assert conflict.kind == "mirror_edited"
    end

    test "a delete race is read from the suffixed identity too", ctx do
      %{user: user, target: target, link: link} = ctx

      google_mirror(link, source_updated_at: @before_sync)

      google_cached_placeholder(target, @google_event_id,
        etag: "\"3555778156955438\"",
        provider_updated_at: ~U[2026-07-01 15:00:00.000000Z]
      )

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

      assert :ok == Engine.unmirror(link, "source-uid-1", user.id)

      assert [conflict] = conflicts(link)
      assert conflict.kind == "delete_race"
      assert conflict.resolution == "deletion_won"
    end
  end

  describe "the two etags compare in one form" do
    test "a quoted cache etag matching a bare baseline is not an edit", ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      # The live shapes, exactly: the mirror holds `3573898397004446` because
      # `WriteEtag.extract/1` cleaned it; the cache holds the same value with
      # Google's quotes because `EventNormaliser` stores `raw["etag"]` untouched.
      # These are the *same* etag, so nothing has changed and no row may be
      # written.
      google_mirror(link, source_updated_at: @before_sync, target_etag: "3573898397004446")

      google_cached_placeholder(target, @google_event_id,
        etag: "\"3573898397004446\"",
        provider_updated_at: ~U[2026-07-01 15:00:00.000000Z]
      )

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context -> :ok end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @before_sync}),
                 user.id
               )

      assert conflicts(link) == []
    end

    test "a genuinely different quoted etag is still an edit", ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      # The guard against curing the flood by simply never comparing: normalising
      # both sides must not make every pair equal.
      google_mirror(link, source_updated_at: @before_sync, target_etag: "3573898397004446")

      google_cached_placeholder(target, @google_event_id,
        etag: "\"3555778156955438\"",
        provider_updated_at: ~U[2026-07-01 15:00:00.000000Z]
      )

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context -> :ok end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @before_sync}),
                 user.id
               )

      assert [conflict] = conflicts(link)
      assert conflict.kind == "mirror_edited"
    end

    test "the delete race reads the quoted pair the same way", ctx do
      %{user: user, target: target, link: link} = ctx

      google_mirror(link, source_updated_at: @before_sync, target_etag: "3573898397004446")

      google_cached_placeholder(target, @google_event_id,
        etag: "\"3573898397004446\"",
        provider_updated_at: ~U[2026-07-01 15:00:00.000000Z]
      )

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

      assert :ok == Engine.unmirror(link, "source-uid-1", user.id)

      # An ordinary withdrawal of an untouched placeholder is not a race.
      assert conflicts(link) == []
    end
  end

  describe "the engine's own write, end to end" do
    test "a placeholder the engine wrote and the target then cached produces no conflict",
         ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      # The regression that would flood the live installation. Both defects fixed,
      # the lookup succeeds and `mirror_edited?/2` evaluates for real — so if the
      # engine's own write looks like a stranger's edit, every one of the 105
      # mirrors writes a conflict row on every sweep.
      #
      # Nothing here is hand-placed: the engine writes, the baseline comes from
      # the write's own response, and the cache is then filled with precisely what
      # that write produced, under the identity Google would have filed it under.
      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        oauth_write_response(@google_event_id, etag: "3573898397004446")
      end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @before_sync}),
                 user.id
               )

      assert {:ok, written} = mirror(link)
      assert written.target_provider_event_id == @google_event_id
      assert written.target_etag == "3573898397004446"

      # The target's inbound sync catches up. It caches the placeholder under
      # Google's iCalUID, with Google's quoted entity tag, stamped at the moment
      # the provider applied our write — necessarily after we recorded the row.
      google_cached_placeholder(target, @google_event_id,
        etag: "\"3573898397004446\"",
        provider_updated_at: DateTime.add(written.last_synced_at, 5, :second)
      )

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context ->
        oauth_write_response(@google_event_id, etag: "3573898397004446")
      end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @before_sync}),
                 user.id
               )

      assert conflicts(link) == []
    end

    test "and does not start producing one on the passes that follow", ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      # A sweep runs repeatedly. One clean pass proves nothing about the tenth if
      # the row's baseline drifts, and a drift of one is a row per mirror per
      # sweep thereafter.
      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        oauth_write_response(@google_event_id, etag: "3573898397004446")
      end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @before_sync}),
                 user.id
               )

      assert {:ok, written} = mirror(link)

      google_cached_placeholder(target, @google_event_id,
        etag: "\"3573898397004446\"",
        provider_updated_at: DateTime.add(written.last_synced_at, 5, :second)
      )

      expect(Tymeslot.CalendarMock, :update_event, 5, fn _uid, _data, _context ->
        oauth_write_response(@google_event_id, etag: "3573898397004446")
      end)

      for _sweep <- 1..5 do
        assert :ok ==
                 Engine.mirror(
                   link,
                   source_event(source, %{provider_updated_at: @before_sync}),
                   user.id
                 )
      end

      assert conflicts(link) == []
    end
  end
end
