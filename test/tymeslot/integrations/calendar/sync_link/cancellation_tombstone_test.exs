defmodule Tymeslot.Integrations.Calendar.SyncLink.CancellationTombstoneTest do
  @moduledoc """
  The delta tombstone Google sends for a cancelled occurrence, driven through
  the real sync path, and the two things that must both be true of it.

  ## The shape, and why nothing here composes it

  Every payload comes from `SyncLinkTestHelpers.google_delta_cancellation/2`,
  transcribed from a body captured off the live API with the sync queue paused:
  six keys, no `start`, no `end`, **no `iCalUID`**.

  That last absence is the whole reason four earlier fixes shipped green and
  failed live. The fixtures they were written against stamped
  `"{master}@google.com"` onto cancelled occurrences, which handed the code the
  series uid it is supposed to derive. With the real body the derivation is
  load-bearing: `uid: raw["iCalUID"] || raw["id"]` yields the *instance* id,
  `{master}_{stamp}`, which no cache row, no mirror row and no write-back job is
  keyed by — so the correction is enqueued against a uid nothing reads.

  ## Two requirements pulling opposite ways

  Detection must see the tombstone; the cache must never hold it.

  `Sync.persist_normalised_events/2` hands the *same* list to `upsert_cache/2`
  and `post_commit_reconciliation/2`. A tombstone carries the series uid — which
  is exactly what makes it reach the right mirror row — and `upsert_batch/1`
  deduplicates on `{calendar_integration_id, uid}` keeping the **last** entry.
  So a tombstone reaching the cache after its siblings overwrites the series row
  with `status: :cancelled` and no timing at all, destroying the row the
  placeholder is expanded from and unblocking every occurrence still scheduled.

  That is a worse bug than the stale block this path exists to clear, so both
  halves are asserted here, on the same sync, in both orders.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :sync_links
  @moduletag :workers

  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.Factory
  import Tymeslot.GoogleDeltaFixtures
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.SyncGoogleCalendarWorker
  alias Tymeslot.Workers.SyncLinkWriteBackWorker

  setup :verify_on_exit!

  @master_id "75l8rnlc9vhfnpvtulucllc7kg"
  @series_uid "75l8rnlc9vhfnpvtulucllc7kg@google.com"
  @cancelled_at "2026-09-07T09:00:00Z"

  setup do
    user = insert(:user)

    source =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        google_sync_token: "valid-token"
      )

    target = insert(:calendar_integration, user: user, provider: "google")

    insert(:calendar_sync_link,
      user_id: user.id,
      source_integration_id: source.id,
      target_integration_id: target.id
    )

    %{source: source}
  end

  defp sync(source, events) do
    expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
      {:ok, %{events: events, next_sync_token: "token-1"}}
    end)

    perform_job(SyncGoogleCalendarWorker, %{"calendar_integration_id" => source.id})
  end

  defp tombstone, do: google_delta_cancellation(@master_id, @cancelled_at)

  defp confirmed_last,
    do: google_delta_occurrence(@master_id, "20260921T090000Z", "2026-09-21T09:00:00Z")

  defp series_rows(source) do
    ProviderCalendarEventSchema
    |> Repo.all()
    |> Enum.filter(&(&1.calendar_integration_id == source.id))
  end

  defp write_back_moves do
    Enum.find_value(all_enqueued(worker: SyncLinkWriteBackWorker), fn job ->
      if job.args["source_uid"] == @series_uid, do: job.args["moved"]
    end)
  end

  describe "detection sees the tombstone" do
    test "the EXDATE reaches the write-back args under the series uid", %{source: source} do
      assert :ok = sync(source, [tombstone(), confirmed_last()])

      assert write_back_moves() == [
               %{"original_start" => @cancelled_at, "new_start" => nil}
             ]
    end

    # The delta carries only what changed, so a cancellation commonly arrives
    # with no sibling beside it. The uid then cannot come from a sibling in the
    # same batch either — it is derived, or it is wrong.
    test "arriving alone, with no sibling in the batch", %{source: source} do
      assert :ok = sync(source, [tombstone()])

      assert write_back_moves() == [
               %{"original_start" => @cancelled_at, "new_start" => nil}
             ]
    end
  end

  describe "the cache never holds the tombstone" do
    # The ordering that does the damage: the tombstone sorts last, so under
    # `upsert_batch/1`'s keep-the-last dedup it is the entry that would win.
    test "a tombstone after its sibling does not overwrite the series row",
         %{source: source} do
      assert :ok = sync(source, [confirmed_last(), tombstone()])

      assert [row] = series_rows(source)
      assert row.uid == @series_uid
      assert row.status == "confirmed"
      assert row.start_at == ~U[2026-09-21 09:00:00.000000Z]
    end

    test "a tombstone before its sibling leaves the same single row", %{source: source} do
      assert :ok = sync(source, [tombstone(), confirmed_last()])

      assert [row] = series_rows(source)
      assert row.uid == @series_uid
      assert row.status == "confirmed"
    end

    # The other half of the split: no phantom row keyed by the instance id
    # either. One was observed during diagnosis.
    test "arriving alone it creates no row at all", %{source: source} do
      assert :ok = sync(source, [tombstone()])

      assert series_rows(source) == []
    end
  end

  # The tombstone test is `status == cancelled` **and no `start`**, and the
  # second half is not redundant. Google also emits a fully-described cancelled
  # occurrence — a complete event body whose status happens to be cancelled,
  # carrying its own `iCalUID`, `start` and `end`. That is an event, not a
  # tombstone: it is cached as one (so availability reads it and
  # `blocking?/1` stops it blocking), and detected through the ordinary path.
  # Routing it to the tombstone branch would silently drop the series' cache row
  # instead of updating it.
  describe "a fully-described cancelled occurrence is not a tombstone" do
    test "it is still cached, with its timing intact", %{source: source} do
      described =
        google_delta_occurrence(@master_id, "20260907T090000Z", @cancelled_at,
          status: "cancelled"
        )

      assert :ok = sync(source, [described])

      assert [row] = series_rows(source)
      assert row.uid == @series_uid
      assert row.status == "cancelled"
      assert row.start_at == ~U[2026-09-07 09:00:00.000000Z]
    end
  end

  describe "the uid the tombstone is enqueued under" do
    # The cache is the authority when it has the answer, and it holds the uid as
    # fact rather than by convention — which is what a series imported into
    # Google under a foreign UID depends on.
    test "is read from the cached series when the master is known", %{source: source} do
      insert(:provider_calendar_event,
        calendar_integration: source,
        uid: "imported-from-elsewhere@example.org",
        provider: "google",
        provider_event_id: "#{@master_id}_20260921T090000Z",
        recurring_event_id: @master_id
      )

      assert :ok = sync(source, [tombstone()])

      assert Enum.find_value(all_enqueued(worker: SyncLinkWriteBackWorker), fn job ->
               if job.args["moved"] != nil and job.args["moved"] != [],
                 do: job.args["source_uid"]
             end) == "imported-from-elsewhere@example.org"
    end

    # And falls back to Google's convention only when there is nothing cached to
    # fail closed against.
    test "falls back to the Google convention when the series is not cached",
         %{source: source} do
      assert :ok = sync(source, [tombstone()])

      assert write_back_moves() == [
               %{"original_start" => @cancelled_at, "new_start" => nil}
             ]
    end
  end

  describe "the correction reaches the provider payload" do
    test "the placeholder is written with an EXDATE at the cancelled instant",
         %{source: source} do
      assert :ok = sync(source, [tombstone(), confirmed_last()])

      expect(GoogleCalendarAPIMock, :get_event, fn _integration, _calendar_id, _event_id ->
        {:ok, google_series_master(master_id: @master_id, rule: "RRULE:FREQ=WEEKLY;COUNT=5")}
      end)

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        {:ok, %{uid: "target-placeholder-1"}}
      end)

      job =
        Enum.find(
          all_enqueued(worker: SyncLinkWriteBackWorker),
          &(&1.args["source_uid"] == @series_uid)
        )

      assert :ok = perform_job(SyncLinkWriteBackWorker, job.args)

      assert_received {:payload, payload}

      assert payload.recurrence_rule == "RRULE:FREQ=WEEKLY;COUNT=5"
      assert "EXDATE;TZID=Etc/UTC:20260907T090000" in payload.recurrence_exception_lines
    end
  end

  describe "the admin alert" do
    # A normal cancellation is not an invalid event, and the system alerted on
    # every one of them. Genuinely malformed payloads must still alert, which
    # the sibling assertion below pins.
    test "is not raised for a tombstone", %{source: source} do
      log = capture_log(fn -> assert :ok = sync(source, [tombstone()]) end)

      refute log =~ "ADMIN ALERT"
      refute log =~ "Skipping invalid Google calendar event"
    end

    # The suppression's only *reachable* branch, and the one that pins it. A
    # well-formed tombstone never reaches the skip path at all, so a test using
    # one passes whether or not the suppression exists. A tombstone missing
    # `originalStartTime` does reach it: the payload is cancelled, names a
    # series and carries no start — Google's own shape — but describes no
    # instant to except, so it is refused. That refusal is a provider oddity
    # worth a log and not an operator page.
    test "is not raised for a tombstone that fails validation", %{source: source} do
      without_instant = Map.delete(tombstone(), "originalStartTime")

      log = capture_log(fn -> assert :ok = sync(source, [without_instant]) end)

      assert log =~ "Skipping invalid Google calendar event"
      refute log =~ "ADMIN ALERT"
    end

    test "is still raised for a genuinely malformed event", %{source: source} do
      malformed = %{
        "id" => "broken-1",
        "iCalUID" => "broken-1@google.com",
        "status" => "confirmed",
        "start" => %{"dateTime" => "not-a-timestamp"},
        "end" => %{"dateTime" => "not-a-timestamp"}
      }

      assert capture_log(fn -> assert :ok = sync(source, [malformed]) end) =~ "ADMIN ALERT"
    end
  end
end
