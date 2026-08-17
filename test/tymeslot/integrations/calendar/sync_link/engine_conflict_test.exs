defmodule Tymeslot.Integrations.Calendar.SyncLink.EngineConflictTest do
  @moduledoc """
  What the engine records when the two sides of a mirror disagree.

  The audit is the whole point: a placeholder that moves, reverts, or vanishes
  without explanation is indistinguishable from a bug, and the organiser has no
  other way to find out which it was. So every non-trivial resolution has to
  leave a row.

  "Exactly one row" is asserted everywhere rather than "at least one". A
  divergence logged twice — once by the branch that detected it and once by the
  branch that resolved it — reads as two separate incidents in a history whose
  only value is that it is a faithful sequence, and the two are indistinguishable
  after the fact.
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

  @synced_at ~U[2026-07-01 12:00:00.000000Z]
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

  # The mirror as the engine left it on its last successful write: the etag the
  # target reported for the placeholder, and the source state it was written
  # from.
  defp synced_mirror(link, attrs) do
    mirror_for_link(
      link,
      Keyword.merge(
        [
          source_uid: "source-uid-1",
          target_uid: Engine.target_uid_for(link.id, "source-uid-1"),
          target_provider_event_id: "target-pid-1",
          target_etag: "etag-as-written",
          last_synced_at: @synced_at
        ],
        attrs
      )
    )
  end

  # The placeholder as the target's own inbound sync has since cached it. This
  # is where a direct edit on the target becomes visible without a provider
  # round trip per event.
  #
  # The default is the untouched case: the etag the engine recorded, stamped at
  # the moment of the write. An edit is expressed by overriding both — a
  # different etag *and* a stamp later than the write, which is what tells a
  # third party's edit from the engine's own.
  defp cached_placeholder(target, link, attrs \\ []) do
    insert(
      :provider_calendar_event,
      Keyword.merge(
        [
          calendar_integration: target,
          uid: Engine.target_uid_for(link.id, "source-uid-1"),
          summary: "Busy",
          provider: "google",
          provider_event_id: "target-pid-1",
          etag: "etag-as-written",
          provider_updated_at: @synced_at
        ],
        attrs
      )
    )
  end

  # The placeholder row as the target's next inbound sync rewrites it. An
  # update rather than an insert, because the cache is unique on
  # `{calendar_integration_id, uid}` — a sync refreshes the row it already has.
  defp resync_placeholder(target, link, attrs) do
    {:ok, cached} =
      ProviderCalendarEventQueries.get_by_uid(
        target.id,
        Engine.target_uid_for(link.id, "source-uid-1")
      )

    cached
    |> Changeset.change(Map.new(attrs))
    |> Repo.update!()
  end

  # The same placeholder after somebody edited it on the target: a different
  # etag, and a stamp later than the engine's write so it cannot be mistaken for
  # the etag bump the write itself caused.
  defp edited_placeholder(target, link, attrs \\ []) do
    cached_placeholder(
      target,
      link,
      Keyword.merge([etag: "etag-edited-by-hand", provider_updated_at: @after_sync], attrs)
    )
  end

  defp conflicts(link), do: CalendarSyncConflictQueries.list_for_link(link.id)

  describe "mirror_edited" do
    test "records one row when the placeholder's etag no longer matches", ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      synced_mirror(link, source_updated_at: @before_sync, source_etag: "source-etag-1")
      edited_placeholder(target, link)

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context -> :ok end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @before_sync, etag: "source-etag-1"}),
                 user.id
               )

      assert [conflict] = conflicts(link)
      assert conflict.kind == "mirror_edited"
      assert conflict.resolution == "source_won"
      assert conflict.source_uid == "source-uid-1"
      assert conflict.detail["target_etag_written"] == "etag-as-written"
      assert conflict.detail["target_etag_observed"] == "etag-edited-by-hand"
    end

    test "records nothing when the placeholder is untouched", ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      synced_mirror(link, source_updated_at: @before_sync)
      cached_placeholder(target, link)

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context -> :ok end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @before_sync}),
                 user.id
               )

      assert conflicts(link) == []
    end

    test "records nothing when no etag was ever written to compare against", ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      # A provider that reports no etag on write gives nothing to diff, and
      # guessing "edited" from its absence would log a conflict on every pass.
      synced_mirror(link, target_etag: nil, source_updated_at: @before_sync)
      cached_placeholder(target, link, etag: "whatever-the-target-says")

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context -> :ok end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @before_sync}),
                 user.id
               )

      assert conflicts(link) == []
    end

    test "overwrites the edited placeholder rather than backing off", ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      synced_mirror(link, source_updated_at: @before_sync)
      edited_placeholder(target, link)

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, data, _context ->
        assert data.summary == "Busy"
        :ok
      end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @before_sync}),
                 user.id
               )

      assert {:ok, mirror} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")

      assert mirror.state == "active"
    end
  end

  describe "both_changed" do
    test "records one row and lets the newer source win", ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      synced_mirror(link, source_updated_at: @before_sync, source_etag: "source-etag-1")

      edited_placeholder(target, link, provider_updated_at: @after_sync)

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context -> :ok end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @later_still, etag: "source-etag-2"}),
                 user.id
               )

      assert [conflict] = conflicts(link)
      assert conflict.kind == "both_changed"
      assert conflict.resolution == "source_won"
      assert conflict.detail["winner"] == "source"
      assert conflict.detail["source_updated_at"] == DateTime.to_iso8601(@later_still)
      assert conflict.detail["target_updated_at"] == DateTime.to_iso8601(@after_sync)
      assert conflict.detail["target_etag_written"] == "etag-as-written"
      assert conflict.detail["target_etag_observed"] == "etag-edited-by-hand"
    end

    test "records one row even when the target's edit is the newer one", ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      # The source still overwrites — mirrors are not independently editable —
      # but the organiser loses an edit here, which is exactly the case the log
      # exists to explain. Logging only when the source wins would leave the
      # one resolution that destroys work unrecorded.
      synced_mirror(link, source_updated_at: @before_sync)

      edited_placeholder(target, link, provider_updated_at: @later_still)

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context -> :ok end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @after_sync}),
                 user.id
               )

      assert [conflict] = conflicts(link)
      assert conflict.kind == "both_changed"
      assert conflict.resolution == "source_won"
      assert conflict.detail["winner"] == "target"
    end

    test "falls back to etag inequality when the provider reports no timestamp", ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      synced_mirror(link,
        source_updated_at: nil,
        source_etag: "source-etag-1",
        last_synced_at: @synced_at
      )

      edited_placeholder(target, link, provider_updated_at: nil)

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context -> :ok end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: nil, etag: "source-etag-2"}),
                 user.id
               )

      assert [conflict] = conflicts(link)
      assert conflict.kind == "both_changed"
      assert conflict.resolution == "source_won"
      assert conflict.detail["compared_by"] == "etag"
      assert conflict.detail["source_etag_written"] == "source-etag-1"
      assert conflict.detail["source_etag_observed"] == "source-etag-2"
    end

    test "is a plain mirror_edited when only the placeholder moved", ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      synced_mirror(link, source_updated_at: @after_sync, source_etag: "source-etag-1")
      edited_placeholder(target, link)

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context -> :ok end)

      # The source is unchanged since the last write, so only one side moved.
      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @after_sync, etag: "source-etag-1"}),
                 user.id
               )

      assert [conflict] = conflicts(link)
      assert conflict.kind == "mirror_edited"
    end
  end

  describe "write_failed" do
    test "records one row when the final attempt's write fails", ctx do
      %{user: user, source: source, link: link} = ctx

      synced_mirror(link, source_updated_at: @before_sync)

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context ->
        {:error, :forbidden}
      end)

      assert {:error, :forbidden} ==
               Engine.mirror(link, source_event(source), user.id, attempt: 5)

      assert [conflict] = conflicts(link)
      assert conflict.kind == "write_failed"
      assert conflict.resolution == "skipped"
      assert conflict.detail["error"] == "forbidden"
      assert conflict.detail["operation"] == "update"
    end

    test "records one row when a create fails terminally", ctx do
      %{user: user, source: source, link: link} = ctx

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:error, :rate_limited}
      end)

      assert {:error, :rate_limited} ==
               Engine.mirror(link, source_event(source), user.id, attempt: 5)

      assert [conflict] = conflicts(link)
      assert conflict.kind == "write_failed"
      assert conflict.resolution == "skipped"
      assert conflict.detail["error"] == "rate_limited"
      assert conflict.detail["operation"] == "create"
    end

    test "records one row when a delete fails terminally", ctx do
      %{user: user, link: link} = ctx

      synced_mirror(link, source_updated_at: @before_sync)

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        {:error, :service_unavailable}
      end)

      assert {:error, :service_unavailable} ==
               Engine.unmirror(link, "source-uid-1", user.id, attempt: 5)

      assert [conflict] = conflicts(link)
      assert conflict.kind == "write_failed"
      assert conflict.resolution == "skipped"
      assert conflict.detail["operation"] == "delete"
    end

    test "records nothing while attempts remain", ctx do
      %{user: user, source: source, link: link} = ctx

      # A transient failure that Oban will retry is not a resolution — it is a
      # write still in flight. Logging it would fill the history with rows for
      # writes that went on to succeed a second later.
      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:error, :timeout}
      end)

      assert {:error, :timeout} == Engine.mirror(link, source_event(source), user.id, attempt: 1)

      assert conflicts(link) == []
    end

    test "the orphan-compensation path still deletes and still surfaces its own error", ctx do
      %{user: user, source: source, link: link} = ctx

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        oauth_write_response("orphan-pid")
      end)

      expect(Tymeslot.CalendarMock, :delete_event, fn uid, _context, _opts ->
        send(test_pid, {:compensated, uid})
        :ok
      end)

      doomed = %{link | id: link.id + 10_000}

      assert {:error, _reason} = Engine.mirror(doomed, source_event(source), user.id, attempt: 5)

      assert_received {:compensated, _uid}

      # The link the conflict would be written against does not exist, so the
      # audit cannot record it — and must not take the compensation down with
      # it.
      assert conflicts(link) == []
    end
  end

  describe "delete_race" do
    test "records one row and lets the deletion win", ctx do
      %{user: user, target: target, link: link} = ctx

      synced_mirror(link, source_updated_at: @before_sync)
      edited_placeholder(target, link)

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

      assert :ok == Engine.unmirror(link, "source-uid-1", user.id)

      assert [conflict] = conflicts(link)
      assert conflict.kind == "delete_race"
      assert conflict.resolution == "deletion_won"
      assert conflict.detail["target_etag_written"] == "etag-as-written"
      assert conflict.detail["target_etag_observed"] == "etag-edited-by-hand"

      assert {:error, :not_found} ==
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")
    end

    test "records nothing when the placeholder was never touched", ctx do
      %{user: user, target: target, link: link} = ctx

      synced_mirror(link, source_updated_at: @before_sync)
      cached_placeholder(target, link)

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

      assert :ok == Engine.unmirror(link, "source-uid-1", user.id)

      # An ordinary withdrawal is not a conflict. Logging one for every deleted
      # source would bury the races the log exists to show.
      assert conflicts(link) == []
    end

    test "records one row per race, not one per attempt at withdrawing it", ctx do
      %{user: user, target: target, link: link} = ctx

      synced_mirror(link, source_updated_at: @before_sync)
      edited_placeholder(target, link)

      # The first delete fails, so the mapping survives in `pending_delete` and
      # the sweep retries it against the same evidence: the placeholder's cached
      # row still carries the etag that showed it had been edited. One race is
      # one event, however many attempts it takes to finish, and this is the
      # double-log the design has to prevent.
      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        {:error, :service_unavailable}
      end)

      assert {:error, :service_unavailable} ==
               Engine.unmirror(link, "source-uid-1", user.id, attempt: 1)

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

      assert :ok == Engine.unmirror(link, "source-uid-1", user.id, attempt: 2)

      assert [conflict] = conflicts(link)
      assert conflict.kind == "delete_race"
      assert conflict.resolution == "deletion_won"
    end

    test "a race and the terminal failure to act on it are two separate facts", ctx do
      %{user: user, target: target, link: link} = ctx

      synced_mirror(link, source_updated_at: @before_sync)
      edited_placeholder(target, link)

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        {:error, :service_unavailable}
      end)

      assert {:error, :service_unavailable} ==
               Engine.unmirror(link, "source-uid-1", user.id, attempt: 5)

      # The organiser's edit lost to a deletion, *and* the placeholder is still
      # sitting on the target because the provider refused to remove it.
      # Collapsing the two into one row would hide whichever was collapsed away.
      assert [failure, race] = conflicts(link)
      assert race.kind == "delete_race"
      assert failure.kind == "write_failed"
      assert failure.detail["operation"] == "delete"
    end
  end

  describe "one divergence, one row" do
    test "a placeholder edited once is recorded once however often it is mirrored", ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      synced_mirror(link, source_updated_at: @before_sync)
      edited_placeholder(target, link)

      expect(Tymeslot.CalendarMock, :update_event, 2, fn _uid, _data, _context -> :ok end)

      # Two passes over the same unchanged evidence — the write-back job and the
      # reconcile sweep both reach the same event, which is the ordinary case
      # rather than an exotic one. The second pass has had its baseline
      # re-stamped by the first and has nothing left to report.
      for _pass <- 1..2 do
        assert :ok ==
                 Engine.mirror(
                   link,
                   source_event(source, %{provider_updated_at: @before_sync}),
                   user.id
                 )
      end

      assert [conflict] = conflicts(link)
      assert conflict.kind == "mirror_edited"
    end

    test "the engine's own write is not reported as a hand edit once the target syncs", ctx do
      %{user: user, source: source, target: target, link: link} = ctx

      # No divergence to begin with: the placeholder is exactly as it was
      # written, and the mirror's baseline matches it.
      synced_mirror(link, source_updated_at: @before_sync, source_etag: "source-etag-1")
      cached_placeholder(target, link, etag: "etag-as-written", provider_updated_at: @synced_at)

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context -> :ok end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @after_sync}),
                 user.id
               )

      # The write lands, and the target's own inbound sync catches up
      # afterwards — which is the only moment the placeholder's new etag can
      # reach our cache at all. Its `provider_updated_at` is when the *provider*
      # applied our write, so it is necessarily later than the moment we
      # recorded the baseline.
      #
      # That ordering is the whole difficulty. The baseline recorded at write
      # time must already describe the event as written; reading it from a cache
      # that has not re-synced stores the *pre*-write etag, and the next pass
      # then compares the engine's own change against it, finds a later
      # timestamp, and calls the engine a stranger.
      {:ok, written} =
        CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")

      resync_placeholder(target, link,
        etag: "etag-after-our-write",
        provider_updated_at: DateTime.add(written.last_synced_at, 5, :second)
      )

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context -> :ok end)

      assert :ok ==
               Engine.mirror(
                 link,
                 source_event(source, %{provider_updated_at: @after_sync}),
                 user.id
               )

      assert [] == conflicts(link)
    end
  end
end
