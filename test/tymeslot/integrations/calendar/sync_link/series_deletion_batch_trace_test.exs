defmodule Tymeslot.Integrations.Calendar.SyncLink.SeriesDeletionBatchTraceTest do
  @moduledoc """
  The batch-level half of the deleted-series trace: what a mixed delta does,
  what distinguishes a deleted series from a single cancelled occurrence, and
  the one-off deletion path a fix must not break.

  Split from `SeriesDeletionTraceTest` — which traces the per-hop mechanics —
  because these three ask a different question. Every test here is about the
  *batch*: how many tombstones arrived, what else came with them, and whether
  any single entry could have told them apart.

  Payloads come from `Tymeslot.GoogleDeltaFixtures`, transcribed from
  `test/support/captured/google_recurring_series.md`.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :sync_links
  @moduletag :workers

  import Mox
  import Tymeslot.Factory
  import Tymeslot.GoogleDeltaFixtures
  import Tymeslot.SeriesDeletionTraceHelpers
  import Tymeslot.SyncLinkTestHelpers, only: [google_series_master: 1]

  alias Tymeslot.Integrations.Calendar.Sync
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

  defp deletion_tombstones, do: google_delta_series_deletion(@master_id, @occurrences)

  defp jobs_for(uid) do
    Enum.filter(all_enqueued(worker: SyncLinkWriteBackWorker), &(&1.args["source_uid"] == uid))
  end

  # ------------------------------------------------------------------
  # Hop H — a partial batch
  # ------------------------------------------------------------------

  describe "hop H: a batch mixing a deleted series with ordinary events" do
    test "the ordinary event is still cached alongside the tombstones",
         %{source: source} do
      cache_the_series(source)

      ordinary = %{
        "id" => "ordinary-1",
        "iCalUID" => "ordinary-1@google.com",
        "kind" => "calendar#event",
        "status" => "confirmed",
        "summary" => "Standalone",
        "start" => %{"dateTime" => "2026-09-10T09:00:00Z", "timeZone" => "UTC"},
        "end" => %{"dateTime" => "2026-09-10T10:00:00Z", "timeZone" => "UTC"}
      }

      assert :ok = sync(source, deletion_tombstones() ++ [ordinary])

      uids = Enum.sort(Enum.map(cached_rows(source), & &1.uid))
      assert "ordinary-1@google.com" in uids

      assert length(uids) == 2,
             "expected the series row and the ordinary row, got #{inspect(uids)}"
    end

    # And a ref that cannot be resolved does not abort the rest of the batch on
    # the deletion side either.
    test "one unresolvable ref does not abort the others", %{source: source, link: link} do
      cache_the_series(source)
      mirror_the_series(link)

      other =
        insert(:provider_calendar_event,
          calendar_integration: source,
          uid: "other@google.com",
          provider: "google",
          provider_event_id: "other"
        )

      refs = [
        %{provider_event_id: "unresolvable", uid: nil},
        %{provider_event_id: other.provider_event_id, uid: other.uid}
      ]

      assert :ok = Sync.reconcile_deletions(source, refs)

      uids = Enum.map(cached_rows(source), & &1.uid)
      refute "other@google.com" in uids
      assert @series_uid in uids
    end
  end

  # ------------------------------------------------------------------
  # Hop J — telling a deletion from a cancellation
  # ------------------------------------------------------------------

  describe "hop J: a deletion and a cancellation are indistinguishable per entry" do
    # The claim in the fixture's doc, tested as a property of the payloads: one
    # tombstone from a deleted series is byte-identical to a tombstone from a
    # single cancelled occurrence. Only the batch differs.
    test "one deletion tombstone equals the cancellation constructor's output" do
      [first | _rest] = google_delta_series_deletion(@master_id, @occurrences)

      assert first == google_delta_cancellation(@master_id, @occ_1)
      assert map_size(first) == 6
    end

    # Stated as a set: EVERY entry of a deletion batch is equal to the
    # cancellation constructor's output for the same instant. There is no field
    # anywhere in the payload that a per-event predicate could branch on.
    test "every deletion tombstone is equal to its cancellation counterpart" do
      deletion = google_delta_series_deletion(@master_id, @occurrences)
      singles = Enum.map(@occurrences, &google_delta_cancellation(@master_id, &1))

      assert deletion == singles

      key_sets = Enum.uniq(Enum.map(deletion, fn t -> Enum.sort(Map.keys(t)) end))

      assert key_sets == [
               ["etag", "id", "kind", "originalStartTime", "recurringEventId", "status"]
             ]
    end

    # What DOES differ is coverage: a deletion cancels every occurrence the rule
    # expands, a cancellation cancels a strict subset. Deciding between them
    # therefore needs the master's rule — which the delta does not carry, and
    # which for a deleted series can no longer be fetched.
    test "the master's rule is what says whether the batch covers the series" do
      master = google_series_master(master_id: @master_id, rule: "RRULE:FREQ=WEEKLY;COUNT=3")

      assert master["recurrence"] == ["RRULE:FREQ=WEEKLY;COUNT=3"]

      assert length(google_delta_series_deletion(@master_id, @occurrences)) == 3,
             "3 tombstones against a COUNT=3 rule is total coverage"

      assert length(google_delta_series_deletion(@master_id, [@occ_1])) == 1,
             "1 tombstone against the same rule is a single cancellation"
    end

    # And the regression 5d1a4ded guards: ONE cancelled occurrence must still
    # produce a correction, never a withdrawal. This is the behaviour any fix
    # must preserve.
    test "a single cancelled occurrence still corrects rather than withdraws",
         %{source: source, link: link} do
      cache_the_series(source)
      mirror_the_series(link)

      assert :ok = sync(source, [google_delta_cancellation(@master_id, @occ_2)])

      assert [job] = jobs_for(@series_uid)
      assert job.args["operation"] == "upsert"
      assert [%{"original_start" => @occ_2, "new_start" => nil}] = job.args["moved"]

      assert [_row] = cached_rows(source), "the series row must survive one cancellation"
    end

    # The batch-level signal that IS available without a provider call, measured
    # so the recommendation rests on a number rather than an argument: a
    # deletion's tombstones all name one master, and there are as many of them
    # as the series had occurrences. Neither fact is readable from one entry.
    test "a deletion batch names exactly one master across all its entries" do
      deletion = google_delta_series_deletion(@master_id, @occurrences)

      masters = deletion |> Enum.map(& &1["recurringEventId"]) |> Enum.uniq()

      assert masters == [@master_id]
      assert length(deletion) == 3
    end
  end

  # ------------------------------------------------------------------
  # Hop I — the non-recurring deletion, guarded
  # ------------------------------------------------------------------

  describe "hop I: the one-off deletion path is intact" do
    test "a deleted one-off withdraws its placeholder", %{source: source, link: link} do
      insert(:provider_calendar_event,
        calendar_integration: source,
        uid: "one-off@google.com",
        provider: "google",
        provider_event_id: "one-off"
      )

      mirror_for_link(link, source_uid: "one-off@google.com")

      one_off = %{
        "id" => "one-off",
        "iCalUID" => "one-off@google.com",
        "kind" => "calendar#event",
        "status" => "cancelled"
      }

      assert :ok = sync(source, [one_off])

      assert [job] = jobs_for("one-off@google.com")
      assert job.args["operation"] == "delete"
    end
  end
end
