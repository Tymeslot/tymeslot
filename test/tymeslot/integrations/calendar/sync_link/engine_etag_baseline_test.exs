defmodule Tymeslot.Integrations.Calendar.SyncLink.EngineEtagBaselineTest do
  @moduledoc """
  That a write's own etag becomes the mirror's baseline, and that the three
  etag-based conflict kinds fire from it.

  `EngineConflictTest` covers the classification, but every mirror row in it is
  hand-inserted with a `target_etag` already in place. That is what let those
  three kinds pass a green suite for as long as they were dead in production:
  the engine wrote `nil` into that column on every real write, so nothing ever
  had a baseline to compare against and the classifier was never reached.

  So the rule these tests hold is the one that suite cannot: the baseline has to
  come *from the write*, through the engine, with no test fixture standing in
  for it. Each of them mirrors first and asserts on the row the engine left,
  rather than on a row it was handed.

  The absent-etag cases are the regression guard that matters most. A provider
  reporting no etag must record `nil` and produce no conflict of any kind — a
  false row is worse than an empty log, because the log is read precisely when
  somebody is trying to find out why a calendar looks wrong.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :sync_links

  import Mox
  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarSyncConflictQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.SyncLink.Engine

  setup :verify_on_exit!

  setup do
    linked_pair()
  end

  @before_sync ~U[2026-07-01 09:00:00.000000Z]
  @after_sync ~U[2026-07-01 15:00:00.000000Z]
  @later_still ~U[2026-07-01 18:00:00.000000Z]

  defp source_event(source, attrs \\ %{}) do
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

  # A write result as the *engine* receives one, which is not the provider's raw
  # body. `Tymeslot.CalendarMock` stands in for `Calendar.Operations`, and that
  # sits above `OAuthBase.handle_write_api_call/2`: by the time `engine.ex:360`
  # calls `WriteEtag.extract/1`, the body has been through `convert_event/1` and
  # the etag has been merged on under the atom key `:etag`, already stripped of
  # its quotes by `WriteEtag.extract/1` inside the wrapper.
  #
  # This fixture used to hand the engine `%{"id" => ..., "etag" => "\"...\""}` —
  # string keys, quotes intact — and claimed to be "exactly as the API module
  # hands it up". It is, but no API module hands anything up to a mock that has
  # replaced the layer above it. The engine passed because `WriteEtag.extract/1`
  # reads the string key too, so the tests were exercising the raw-body clause
  # while production takes the atom one, and the quote-stripping they appeared to
  # prove was being done here rather than in the code that does it live.
  #
  # The raw body, its `@odata.etag` sibling, and the quote stripping are covered
  # where that shape genuinely occurs: `oauth_base_test.exs`'s
  # "handle_write_api_call/2" describe block and `provider_write_etag_test.exs`.
  defp google_write_response(etag) do
    {:ok, converted} = oauth_write_response("target-pid-1", etag: etag)
    converted
  end

  # The placeholder as the target's own inbound sync later caches it. This is
  # the side a baseline is compared against, and the only way an edit made
  # directly on the target becomes visible without a round trip per event.
  defp cache_placeholder(target, link, attrs) do
    insert(
      :provider_calendar_event,
      Keyword.merge(
        [
          calendar_integration: target,
          uid: target_uid(link),
          summary: "Busy",
          provider: "google",
          provider_event_id: "target-pid-1"
        ],
        attrs
      )
    )
  end

  defp resync_placeholder(target, link, attrs) do
    {:ok, cached} = ProviderCalendarEventQueries.get_by_uid(target.id, target_uid(link))

    cached
    |> Changeset.change(Map.new(attrs))
    |> Repo.update!()
  end

  describe "the baseline a write leaves" do
    test "a create records the provider's own etag as target_etag", ctx do
      %{user: user, source: source, link: link} = ctx

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:ok, google_write_response("3573625707763998")}
      end)

      assert :ok == Engine.mirror(link, source_event(source), user.id)

      assert {:ok, row} = mirror(link)
      assert row.target_etag == "3573625707763998"
    end

    test "an update replaces the baseline with the etag that write produced", ctx do
      %{user: user, source: source, link: link} = ctx

      mirror_for_link(link,
        source_uid: "source-uid-1",
        target_uid: target_uid(link),
        target_etag: "etag-from-the-previous-write",
        last_synced_at: @before_sync
      )

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context ->
        {:ok, google_write_response("etag-from-this-write")}
      end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @before_sync}),
                 user.id
               )

      assert {:ok, row} = mirror(link)
      assert row.target_etag == "etag-from-this-write"
    end

    test "the stored baseline is the same form the cache holds", ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      # The two sides have to compare equal, and this is the assertion that they
      # do: the mirror's `target_etag` and the cache's `etag` column are read
      # against each other on every pass, so a difference in form between them
      # would log a conflict over an untouched placeholder.
      #
      # The quote stripping that makes them agree happens above this layer —
      # `handle_write_api_call/2` cleans the etag before the engine sees it — and
      # is asserted in `oauth_base_test.exs`. What is pinned here is that the
      # engine stores what it was given without reformatting it.
      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:ok, google_write_response("quoted-etag")}
      end)

      assert :ok == Engine.mirror(link, source_event(source), user.id)

      assert {:ok, row} = mirror(link)
      assert row.target_etag == "quoted-etag"

      # And it is the same form the cache holds, which is the whole point of
      # normalising it.
      cache_placeholder(target, link, etag: "quoted-etag", provider_updated_at: @after_sync)
      {:ok, cached} = ProviderCalendarEventQueries.get_by_uid(target.id, target_uid(link))
      assert cached.etag == row.target_etag
    end
  end

  describe "mirror_edited, fired from a real baseline" do
    test "fires when the target's etag has changed since our write", ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      # The write establishes the baseline. Nothing hand-inserts it: this is the
      # step that was missing, and without it none of the rest can happen.
      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:ok, google_write_response("etag-as-written")}
      end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @before_sync}),
                 user.id
               )

      assert {:ok, written} = mirror(link)
      assert written.target_etag == "etag-as-written"

      # Somebody edits the placeholder on the target, and the target's own sync
      # caches the result: a different etag, stamped after our write.
      cache_placeholder(target, link,
        etag: "etag-edited-by-hand",
        provider_updated_at: DateTime.add(written.last_synced_at, 60, :second)
      )

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context ->
        {:ok, google_write_response("etag-after-the-overwrite")}
      end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @before_sync}),
                 user.id
               )

      assert [conflict] = conflicts(link)
      assert conflict.kind == "mirror_edited"
      assert conflict.resolution == "source_won"
      assert conflict.detail["target_etag_written"] == "etag-as-written"
      assert conflict.detail["target_etag_observed"] == "etag-edited-by-hand"

      # And the overwrite re-baselines from its own response, so the next pass
      # over the same untouched placeholder has nothing left to report.
      assert {:ok, rewritten} = mirror(link)
      assert rewritten.target_etag == "etag-after-the-overwrite"
    end

    test "does not fire when the target syncs back the etag our own write produced", ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      # The regression the whole baseline design exists to prevent. Our write
      # bumps the placeholder's etag on the provider; the target's inbound sync
      # then caches that new etag with a `provider_updated_at` of when the
      # provider applied our write — necessarily later than the moment we
      # stamped the row. Read from the cache, that looks exactly like a
      # stranger's edit. Read from the write's own response, it matches.
      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:ok, google_write_response("etag-our-write-produced")}
      end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @before_sync}),
                 user.id
               )

      assert {:ok, written} = mirror(link)

      cache_placeholder(target, link,
        etag: "etag-our-write-produced",
        provider_updated_at: DateTime.add(written.last_synced_at, 5, :second)
      )

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context ->
        {:ok, google_write_response("etag-our-write-produced")}
      end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @before_sync}),
                 user.id
               )

      assert conflicts(link) == []
    end
  end

  describe "both_changed, fired from a real baseline" do
    test "fires when the source moved too, and names the newer side", ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:ok, google_write_response("etag-as-written")}
      end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @before_sync, etag: "source-etag-1"}),
                 user.id
               )

      assert {:ok, written} = mirror(link)

      # Both stamps hang off the row the engine actually wrote, whose
      # `last_synced_at` is real wall-clock time rather than one of the fixed
      # dates above. The placeholder's edit has to land after that write to be
      # readable as a hand edit at all, and the source's has to land after the
      # placeholder's for the source to be the newer side — so anchoring either
      # to a literal would make which side "wins" depend on today's date.
      target_edited_at = DateTime.add(written.last_synced_at, 60, :second)
      source_edited_at = DateTime.add(target_edited_at, 60, :second)

      cache_placeholder(target, link,
        etag: "etag-edited-by-hand",
        provider_updated_at: target_edited_at
      )

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context ->
        {:ok, google_write_response("etag-after-the-overwrite")}
      end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{
                   provider_updated_at: source_edited_at,
                   etag: "source-etag-2"
                 }),
                 user.id
               )

      assert [conflict] = conflicts(link)
      assert conflict.kind == "both_changed"
      assert conflict.resolution == "source_won"
      assert conflict.detail["winner"] == "source"
      assert conflict.detail["target_etag_written"] == "etag-as-written"
      assert conflict.detail["target_etag_observed"] == "etag-edited-by-hand"
    end
  end

  describe "delete_race, fired from a real baseline" do
    test "fires when the placeholder was edited before its source was withdrawn", ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:ok, google_write_response("etag-as-written")}
      end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @before_sync}),
                 user.id
               )

      assert {:ok, written} = mirror(link)

      cache_placeholder(target, link,
        etag: "etag-edited-by-hand",
        provider_updated_at: DateTime.add(written.last_synced_at, 60, :second)
      )

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

      assert :ok == Engine.unmirror(link, "source-uid-1", user.id)

      assert [conflict] = conflicts(link)
      assert conflict.kind == "delete_race"
      assert conflict.resolution == "deletion_won"
      assert conflict.detail["target_etag_written"] == "etag-as-written"
      assert conflict.detail["target_etag_observed"] == "etag-edited-by-hand"
    end
  end

  describe "a provider that reports no etag" do
    test "records nil rather than a placeholder value", ctx do
      %{user: user, source: source, link: link} = ctx

      # The CalDAV shape: a create answers the payload it PUT, carrying the
      # caller's uid and no etag. Outlook's converted response is the same in
      # the respect that matters — no etag key.
      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:ok, %{uid: Engine.target_uid_for(link.id, "source-uid-1"), summary: "Busy"}}
      end)

      assert :ok == Engine.mirror(link, source_event(source), user.id)

      assert {:ok, row} = mirror(link)
      assert row.target_etag == nil
    end

    test "produces no conflict of any kind, however the placeholder is cached", ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      # The guard that matters most. With no baseline, the etag-based kinds are
      # off for this provider — deliberately and by a stated rule, not by
      # accident — so no arrangement of the cached placeholder may produce a
      # row. A false log is worse than an empty one.
      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:ok, %{uid: Engine.target_uid_for(link.id, "source-uid-1")}}
      end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @before_sync}),
                 user.id
               )

      assert {:ok, written} = mirror(link)
      assert written.target_etag == nil

      cache_placeholder(target, link,
        etag: "an-etag-the-target-reports",
        provider_updated_at: DateTime.add(written.last_synced_at, 60, :second)
      )

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context -> :ok end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @later_still}),
                 user.id
               )

      assert conflicts(link) == []

      # And the same on withdrawal: no baseline, no race.
      resync_placeholder(target, link, etag: "changed-again")

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

      assert :ok == Engine.unmirror(link, "source-uid-1", user.id)

      assert conflicts(link) == []
    end

    test "a CalDAV update keeps the row's baseline nil rather than inventing one", ctx do
      %{user: user, source: source, link: link} = ctx

      mirror_for_link(link,
        source_uid: "source-uid-1",
        target_uid: target_uid(link),
        target_etag: nil,
        last_synced_at: @before_sync
      )

      # A bare `:ok` is the CalDAV family reporting the write landed and nothing
      # else. There is no etag to read, and none may be invented.
      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context -> :ok end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @after_sync}),
                 user.id
               )

      assert {:ok, row} = mirror(link)
      assert row.target_etag == nil
    end
  end

  describe "what a write with no etag must not do to an existing baseline" do
    test "clears it rather than leaving a baseline describing an older write", ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      # A provider that answered with an etag once and not the next time. The
      # stale baseline describes a version of the placeholder two writes ago, so
      # keeping it would compare the target against a state neither side is in
      # and report an edit nobody made. `nil` says "no baseline", which is the
      # honest answer and switches the kinds off until a real one arrives.
      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:ok, google_write_response("etag-from-the-first-write")}
      end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @before_sync}),
                 user.id
               )

      assert {:ok, written} = mirror(link)
      assert written.target_etag == "etag-from-the-first-write"

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context -> :ok end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @after_sync}),
                 user.id
               )

      assert {:ok, row} = mirror(link)
      assert row.target_etag == nil

      # And with no baseline, an edited placeholder produces no row.
      cache_placeholder(target, link,
        etag: "etag-edited-by-hand",
        provider_updated_at: @later_still
      )

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context -> :ok end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @after_sync}),
                 user.id
               )

      assert conflicts(link) == []
    end
  end
end
