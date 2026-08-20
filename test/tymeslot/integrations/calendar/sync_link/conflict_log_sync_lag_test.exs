defmodule Tymeslot.Integrations.Calendar.SyncLink.ConflictLogSyncLagTest do
  @moduledoc """
  That the engine's own write is not read as a stranger's edit during the window
  before the target calendar next syncs.

  `ConflictLogIdentityTest` already covers "the engine's own write, end to end",
  and it passes on a build where the live installation flooded. The reason is the
  shape of its fixture: it writes the placeholder, then fills the cache with
  *what that write produced*, so the two etags compare equal and the recency
  guard is never reached. Production never presents that state at the moment of
  comparison. The target syncs on its own schedule — up to 30 minutes later — so
  the cache still holds the etag from **before** our write, and the comparison
  runs against a value our own write has already superseded.

  Measured on the live installation, mirror row id=2338, sync_link_id=1, source
  `50vl4l1hrvsq2e0rau5s46hb60@google.com`:

      09:44:34  the organiser edits the source
      10:00:03  the source syncs into the cache
      10:01:13 ┐ 40 write → conflict → write cycles, ~2 seconds apart,
      10:01:30 ┘ each appending a `mirror_edited` row
      10:30:04  the target syncs; the cached etag catches up; the loop stops

  The signature is in the rows themselves: `target_etag_observed` is frozen at
  `"3573923707063518"` across all three consecutive rows sampled, while
  `target_etag_written` advances every pass — 3574094567998942, 3574094572089822,
  3574094576353854. An observation that does not move while our write does is our
  own write being re-read, not an organiser editing forty times in seventeen
  seconds.

  What made it a loop rather than a single wrong row is that the engine rewrites
  the placeholder as its resolution. Each rewrite mints a new etag, which still
  does not match the stale cache, so the next pass finds the same divergence
  again. It could only terminate when the target's inbound sync finally ran.

  The missing term is recency of the *observation*, and these tests fix which
  timestamps state it. `provider_updated_at` cannot: it records when the provider
  applied a change, and the provider applies **our** write after we record the
  row, so "changed after our write" is true of our own write as much as of
  anyone's — the trap already written down in `ConflictLog`'s moduledoc under
  "Falling back to timestamps". The pair that does state it is the cache row's
  `synced_at`, which says when we last *learned* anything about the placeholder,
  against `mirror.updated_at`, which says when we last wrote it.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :sync_links

  import Mox
  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarSyncConflictQueries
  alias Tymeslot.Integrations.Calendar.SyncLink.Engine

  setup :verify_on_exit!

  setup do
    linked_pair()
  end

  # The bare event id Google filed the placeholder under, in the shape the live
  # rows carry it.
  @google_event_id "k7crcuk3nrsaagh95hf2kb7b4sq2554u"

  # Taken from the live rows: the etag the target's last inbound sync cached,
  # quoted as Google sends it, and the bare form the mirror row holds after
  # `WriteEtag.extract/1`.
  @stale_cached_etag "\"3573923707063518\""
  @written_etag "3574094576353854"

  # The organiser's edit landed before any of this; the source is settled by the
  # time the engine starts rewriting the placeholder.
  @source_edited_at ~U[2026-08-18 09:44:34.000000Z]

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
          start_at: ~U[2026-08-20 09:00:00Z],
          end_at: ~U[2026-08-20 10:00:00Z],
          synced_at: ~U[2026-08-18 10:00:03Z]
        },
        attrs
      )
    )
  end

  defp conflicts(link), do: CalendarSyncConflictQueries.list_for_link(link.id)

  describe "the window before the target's next inbound sync" do
    test "the engine's own write is not a conflict while the cache still holds the pre-write etag",
         ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      # The state at 10:01:13 on the live installation. The target last synced at
      # 10:00 and cached the placeholder as it was *before* this write; the
      # engine is about to write it again, minting an etag the cache has never
      # seen and will not see until 10:30.
      google_cached_placeholder(target, @google_event_id,
        etag: @stale_cached_etag,
        synced_at: ~U[2026-08-18 10:00:03.000000Z],
        # The provider stamps this when it *applies* a write, which is after we
        # record the row that issued it — on the live install
        # `provider_updated_at` 10:01:30.311 sits just under `updated_at`
        # 10:01:30.446 for the write before it. So this value is later than the
        # mapping's own write stamp even though the cache learned nothing new,
        # and that is exactly why the existing guard did not hold: it reads this
        # stamp as evidence of an edit when it is only evidence of our write
        # being applied.
        provider_updated_at: ~U[2026-08-18 10:01:12.500000Z]
      )

      mirror_for_link(link,
        source_uid: "source-uid-1",
        target_uid: Engine.target_uid_for(link.id, "source-uid-1"),
        target_provider_event_id: @google_event_id,
        target_etag: "3574094567998942",
        source_updated_at: @source_edited_at,
        last_synced_at: ~U[2026-08-18 10:01:11.000000Z]
      )

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context ->
        oauth_write_response(@google_event_id, etag: @written_etag)
      end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @source_edited_at}),
                 user.id
               )

      # An observation older than our own last write explains the difference by
      # itself. Nothing here is evidence of anybody touching the placeholder.
      assert conflicts(link) == []
    end

    test "and a sweep of repeated passes does not accumulate rows while the cache stays stale",
         ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      # The loop as it actually ran: 40 passes roughly two seconds apart, the
      # cache frozen throughout because the target does not sync until 10:30.
      # One clean pass proves nothing here — the defect's signature is
      # accumulation, and each pass re-writes the placeholder and re-baselines
      # the row, which is what fed the next comparison.
      google_cached_placeholder(target, @google_event_id,
        etag: @stale_cached_etag,
        synced_at: ~U[2026-08-18 10:00:03.000000Z],
        provider_updated_at: ~U[2026-08-18 10:01:12.500000Z]
      )

      mirror_for_link(link,
        source_uid: "source-uid-1",
        target_uid: Engine.target_uid_for(link.id, "source-uid-1"),
        target_provider_event_id: @google_event_id,
        target_etag: "3574094567998942",
        source_updated_at: @source_edited_at,
        last_synced_at: ~U[2026-08-18 10:01:11.000000Z]
      )

      # Each pass mints a fresh etag, exactly as the live rows show the written
      # value advancing while the observed one stood still.
      expect(Tymeslot.CalendarMock, :update_event, 10, fn _uid, _data, _context ->
        oauth_write_response(@google_event_id,
          etag:
            Integer.to_string(
              System.unique_integer([:positive, :monotonic]) + 3_574_094_567_998_942
            )
        )
      end)

      for _pass <- 1..10 do
        assert :ok ==
                 Engine.mirror(
                   link,
                   source_event(source, %{provider_updated_at: @source_edited_at}),
                   user.id
                 )
      end

      assert conflicts(link) == []
    end
  end

  describe "an edit made by somebody else" do
    test "is still recorded when the target synced after our write", ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      # The feature the fix must not cost. The cached etag is neither the value
      # we wrote nor the one that preceded it, and — this is the part that
      # separates it from the race above — the target has synced *since* we last
      # wrote the row. So the cache is reporting a placeholder state that
      # postdates our write, which only a third party can have produced.
      google_cached_placeholder(target, @google_event_id,
        etag: "\"3574999888777666\"",
        synced_at: ~U[2026-08-18 10:20:00.000000Z],
        provider_updated_at: ~U[2026-08-18 10:19:00.000000Z]
      )

      mirror_for_link(link,
        source_uid: "source-uid-1",
        target_uid: Engine.target_uid_for(link.id, "source-uid-1"),
        target_provider_event_id: @google_event_id,
        target_etag: "3574094567998942",
        source_updated_at: @source_edited_at,
        last_synced_at: ~U[2026-08-18 10:01:11.000000Z],
        # The mapping has not been rewritten since 10:01, so the 10:20 sync is a
        # genuinely newer look at the placeholder. Stamped explicitly because the
        # factory would otherwise date the row to the moment the test ran, which
        # is later than every fixture timestamp above it and would make the
        # observation look stale when the point of the test is that it is fresh.
        updated_at: ~U[2026-08-18 10:01:11.500000Z]
      )

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context ->
        oauth_write_response(@google_event_id, etag: @written_etag)
      end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @source_edited_at}),
                 user.id
               )

      assert [conflict] = conflicts(link)
      assert conflict.kind == "mirror_edited"
      assert conflict.resolution == "source_won"
      assert conflict.detail["target_etag_written"] == "3574094567998942"
      assert conflict.detail["target_etag_observed"] == "\"3574999888777666\""
    end
  end

  describe "once the target has caught up" do
    test "the cached etag equals what we wrote and there is no conflict", ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      # The post-10:30:04 state on the live installation, verbatim: the mirror
      # holds the bare form and the cache the quoted form of the same value, and
      # the cache row is now stamped later than the mapping. Both terms of the
      # test agree there is nothing to report, and the loop stopped here.
      google_cached_placeholder(target, @google_event_id,
        etag: "\"3574094580623678\"",
        synced_at: ~U[2026-08-18 10:30:04.028512Z],
        provider_updated_at: ~U[2026-08-18 10:01:30.311000Z]
      )

      mirror_for_link(link,
        source_uid: "source-uid-1",
        target_uid: Engine.target_uid_for(link.id, "source-uid-1"),
        target_provider_event_id: @google_event_id,
        target_etag: "3574094580623678",
        source_updated_at: @source_edited_at,
        last_synced_at: ~U[2026-08-18 10:01:30.446205Z]
      )

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context ->
        oauth_write_response(@google_event_id, etag: "3574094580623678")
      end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @source_edited_at}),
                 user.id
               )

      assert conflicts(link) == []
    end
  end
end
