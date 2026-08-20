defmodule Tymeslot.Integrations.Calendar.SyncLink.SeriesDeletionWithdrawalTest do
  @moduledoc """
  The deleted-series path, end to end and fixed: a delta of tombstones must take
  the placeholder down.

  Where `SeriesDeletionTraceTest` records what each hop did before the fix, this
  module asserts the outcome the organiser cares about — the busy block for a
  series that no longer exists is withdrawn, its mapping row dropped, and the
  cache row gone.

  ## Why the master, and not the batch, is what decides

  A deleted series arrives as one six-key tombstone per occurrence, and hop J of
  the trace pins that a single tombstone is **element-wise identical** to the
  one a single cancelled occurrence produces. Nothing in the payload separates
  them, and the batch is no better a witness: a delta is paginated and windowed,
  so "every occurrence was cancelled" is not a question one page can answer.

  The master can answer it, and is already fetched. Deleting a series does not
  make `get_event` fail — measured live, it returns the full 19-key body with
  `recurrence` intact and `status: "cancelled"` — so the placeholder write
  already has the deciding fact in hand and used to ignore it.

  That is why these tests drive the real write-back with a **cancelled master**
  rather than a 404. A fix keyed on the fetch failing would pass a test that
  mocked `{:error, :not_found}` and do nothing whatever in production.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :sync_links
  @moduletag :workers

  import Mox
  import Tymeslot.GoogleDeltaFixtures
  import Tymeslot.SeriesDeletionTraceHelpers

  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries
  alias Tymeslot.Integrations.Calendar.SyncLink.RecurringSeries
  alias Tymeslot.Workers.SyncGoogleCalendarWorker
  alias Tymeslot.Workers.SyncLinkWriteBackWorker

  setup :verify_on_exit!

  @master_id Tymeslot.SeriesDeletionTraceHelpers.master_id()
  @series_uid Tymeslot.SeriesDeletionTraceHelpers.series_uid()

  @occ_1 "2026-08-24T09:00:00Z"
  @occ_2 "2026-08-31T09:00:00Z"
  @occ_3 "2026-09-07T09:00:00Z"
  @occurrences [@occ_1, @occ_2, @occ_3]

  setup do
    sync_link_world()
  end

  defp sync(source, events) do
    expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
      {:ok, %{events: events, next_sync_token: "token-1"}}
    end)

    perform_job(SyncGoogleCalendarWorker, %{"calendar_integration_id" => source.id})
  end

  defp jobs_for(uid) do
    Enum.filter(all_enqueued(worker: SyncLinkWriteBackWorker), &(&1.args["source_uid"] == uid))
  end

  defp expect_master(master) do
    expect(GoogleCalendarAPIMock, :get_event, fn _integration, _calendar_id, _event_id ->
      {:ok, master}
    end)
  end

  defp deleted_master, do: google_deleted_series_master(@master_id, @occ_1)
  defp live_master, do: google_series_master(@master_id, @occ_1)

  # ------------------------------------------------------------------
  # The captured shape itself
  # ------------------------------------------------------------------

  describe "the deleted master's captured shape" do
    # The whole fix turns on this body existing rather than the fetch failing.
    # Asserted against the fixture so the claim is about the payload.
    test "it is the live master's key set with status flipped, recurrence intact" do
      live = live_master()
      deleted = deleted_master()

      assert Enum.sort(Map.keys(live)) == Enum.sort(Map.keys(deleted)),
             "a deleted master is the same shape, not a smaller one"

      assert live["status"] == "confirmed"
      assert deleted["status"] == "cancelled"

      assert deleted["recurrence"] == ["RRULE:FREQ=WEEKLY;COUNT=3"],
             "the rule survives the deletion, which is why reading it is not enough"

      assert Map.delete(live, "status") == Map.delete(deleted, "status"),
             "status is the ONLY difference anywhere in the body"
    end

    # And what that shape does to the resolver. Before the fix this answered
    # {:ok, series} and the engine rewrote the placeholder from it.
    test "resolve/2 answers :series_deleted rather than {:ok, series}", %{source: source} do
      expect_master(deleted_master())

      assert :series_deleted =
               RecurringSeries.resolve(%{recurring_event_id: @master_id}, source)
    end

    test "a live master still resolves to a series", %{source: source} do
      expect_master(live_master())

      assert {:ok, %{recurrence_rule: "RRULE:FREQ=WEEKLY;COUNT=3"}} =
               RecurringSeries.resolve(%{recurring_event_id: @master_id}, source)
    end
  end

  # ------------------------------------------------------------------
  # End to end
  # ------------------------------------------------------------------

  describe "a deleted series, end to end" do
    test "the placeholder is withdrawn and the mapping row dropped",
         %{source: source, link: link} do
      cache_the_series(source)
      mirror = mirror_the_series(link)

      assert :ok = sync(source, google_delta_series_deletion(@master_id, @occurrences))

      assert [job] = jobs_for(@series_uid)

      # The master is fetched for the placeholder write, and says the series is
      # gone. The provider delete is then the withdrawal.
      expect_master(deleted_master())
      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

      assert :ok = perform_job(SyncLinkWriteBackWorker, job.args)

      assert {:error, :not_found} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, mirror.source_uid)

      # And the source's own cache row, which nothing on the sync path removes.
      # A surviving `confirmed` row is `CalendarEvent.blocking?/1`, so leaving it
      # would keep the organiser's own availability blocked by a series that no
      # longer exists — the same symptom on the source side.
      assert cached_rows(source) == [],
             "the deleted series' cache row must go too"
    end

    # The uid the withdrawal is keyed by has to be the SERIES uid, which no
    # tombstone carries. It is resolved on the sync, from the cache, before
    # anything is deleted.
    test "the withdrawal is keyed by the series uid, not an instance id",
         %{source: source, link: link} do
      cache_the_series(source)
      mirror_the_series(link)

      assert :ok = sync(source, google_delta_series_deletion(@master_id, @occurrences))

      assert [job] = jobs_for(@series_uid)
      assert job.args["source_uid"] == @series_uid

      refute String.contains?(job.args["source_uid"], "_2026"),
             "an instance id would name no mirror row"
    end

    # A provider 404 means the placeholder was already gone. Still a completed
    # withdrawal, not a retry.
    test "a provider 404 also drops the mapping row", %{source: source, link: link} do
      cache_the_series(source)
      mirror = mirror_the_series(link)

      assert :ok = sync(source, google_delta_series_deletion(@master_id, @occurrences))
      assert [job] = jobs_for(@series_uid)

      expect_master(deleted_master())

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        {:error, :not_found}
      end)

      assert :ok = perform_job(SyncLinkWriteBackWorker, job.args)

      assert {:error, :not_found} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, mirror.source_uid)
    end

    # One tombstone, not three. A windowed or paginated delta carrying a single
    # occurrence of a deleted series must still withdraw, which is exactly what
    # a batch-counting fix could not do.
    test "a single tombstone of a deleted series still withdraws",
         %{source: source, link: link} do
      cache_the_series(source)
      mirror = mirror_the_series(link)

      assert :ok = sync(source, [google_delta_cancellation(@master_id, @occ_2)])

      assert [job] = jobs_for(@series_uid)

      expect_master(deleted_master())
      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

      assert :ok = perform_job(SyncLinkWriteBackWorker, job.args)

      assert {:error, :not_found} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, mirror.source_uid)
    end
  end

  # ------------------------------------------------------------------
  # The regression 5d1a4ded guards
  # ------------------------------------------------------------------

  describe "one cancelled occurrence of a LIVE series" do
    # The guarantee `withdrawn?/1` was introduced to protect: cancelling one
    # occurrence must correct the placeholder with an EXDATE, never withdraw it
    # and take the remaining occurrences down with it.
    test "corrects with an EXDATE and does NOT withdraw", %{source: source, link: link} do
      cache_the_series(source)
      mirror = mirror_the_series(link)

      assert :ok = sync(source, [google_delta_cancellation(@master_id, @occ_2)])

      assert [job] = jobs_for(@series_uid)
      assert job.args["operation"] == "upsert"
      assert [%{"original_start" => @occ_2, "new_start" => nil}] = job.args["moved"]

      # The master is alive: the series still exists, one occurrence of it does not.
      expect_master(live_master())

      exdates =
        capture_written_recurrence(fn ->
          assert :ok = perform_job(SyncLinkWriteBackWorker, job.args)
        end)

      assert Enum.any?(exdates, &String.starts_with?(&1, "EXDATE")),
             "the cancellation must reach the provider as an EXDATE, got #{inspect(exdates)}"

      assert Enum.any?(exdates, &String.starts_with?(&1, "RRULE")),
             "the series itself must still be described"

      assert {:ok, reloaded} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, mirror.source_uid),
             "the mapping row must SURVIVE a single cancellation"

      assert reloaded.target_uid == mirror.target_uid
    end

    test "the series cache row survives one cancellation", %{source: source, link: link} do
      cache_the_series(source)
      mirror_the_series(link)

      assert :ok = sync(source, [google_delta_cancellation(@master_id, @occ_2)])

      assert [_row] = cached_rows(source)
    end
  end

  # Captures the recurrence lines the placeholder write actually sends, so the
  # EXDATE assertion is about what reached the provider rather than about a job
  # argument. Reading the enqueued args instead would pass while the write
  # dropped the correction on the floor.
  #
  # The keys are `MirrorPayload`'s own — `:recurrence_rule` for the RRULE and
  # `:recurrence_exception_lines` for the EXDATEs (`mirror_payload.ex:230-231`).
  # There is no `:recurrence` key: the payload is not a provider body but the
  # shape `CalendarEvents.update_event/3` is handed, and guessing the provider's
  # spelling here would assert over `nil` and pass regardless.
  #
  # `update_event/3`, not /4 — the arity on `CalendarBehaviour`. Mox rejects a
  # wrong arity outright, which is the only reason this was caught rather than
  # quietly matching nothing.
  defp capture_written_recurrence(fun) do
    parent = self()

    expect(Tymeslot.CalendarMock, :update_event, fn _uid, payload, _context ->
      send(parent, {:written, payload})
      {:ok, %{uid: "target-uid"}}
    end)

    fun.()

    receive do
      {:written, payload} ->
        rule = Map.get(payload, :recurrence_rule)
        exceptions = List.wrap(Map.get(payload, :recurrence_exception_lines))

        assert is_binary(rule),
               "the payload carried no recurrence_rule: #{inspect(Map.keys(payload))}"

        [rule | exceptions]
    after
      0 -> flunk("no placeholder write reached the provider")
    end
  end
end
