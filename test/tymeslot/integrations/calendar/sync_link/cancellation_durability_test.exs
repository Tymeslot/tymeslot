defmodule Tymeslot.Integrations.Calendar.SyncLink.CancellationDurabilityTest do
  @moduledoc """
  A cancellation surviving the syncs that follow it.

  ## The asymmetry that made this look like a detection bug

  A cancelled occurrence appears in **exactly one** delta. Google reports it
  once, as an exception instance carrying `status: "cancelled"`, and every later
  delta omits it — there is nothing left to report. A *moved* occurrence is the
  opposite: it keeps carrying an `originalStartTime` differing from its `start`
  on every delta it appears in, so the correction is re-detected each time.

  `WriteBack.enqueue/4` collapses onto a pending job with
  `replace: [available: [:args]]`, which swaps the args **wholesale**. The
  ordinary sync path enqueues a plain `upsert` for every event it sees, with no
  `moved`. So the two kinds of correction have completely different fates when a
  second sync lands before the write-back job runs:

  - a move is re-detected by that sync and re-attached, so it survives;
  - a cancellation is not, so the plain enqueue overwrites it and the correction
    is gone permanently. Nothing re-detects it, and the placeholder keeps
    blocking the slot forever.

  Measured live on a fresh series with the third occurrence cancelled: the one
  write-back job that ran carried `moved = nil` and rewrote the placeholder back
  to a bare `["RRULE:FREQ=WEEKLY;COUNT=5"]`.

  That is why every previous test passed. Each drove a single sync, where the
  report's enqueue is the last word.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :sync_links
  @moduletag :workers

  import Mox
  import Tymeslot.Factory
  import Tymeslot.GoogleDeltaFixtures

  alias Tymeslot.Workers.SyncGoogleCalendarWorker
  alias Tymeslot.Workers.SyncLinkWriteBackWorker

  setup :verify_on_exit!

  @master_id "lvis2ao68dlbl2j92k861eqr30"

  defp sync(source, events, token) do
    expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
      {:ok, %{events: events, next_sync_token: token}}
    end)

    perform_job(SyncGoogleCalendarWorker, %{"calendar_integration_id" => source.id})
  end

  defp pending_moves do
    case all_enqueued(worker: SyncLinkWriteBackWorker) do
      [job] -> job.args["moved"]
      jobs -> {:unexpected_job_count, length(jobs)}
    end
  end

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

  # The third occurrence of five, so the last-occurrence dedup trap is not in
  # play: the row that survives the upsert is the confirmed 20260920 one.
  defp cancelled_third,
    do: google_delta_cancellation(@master_id, "2026-09-06T09:00:00Z")

  defp confirmed_last,
    do: google_delta_occurrence(@master_id, "20260920T090000Z", "2026-09-20T09:00:00Z")

  test "a cancellation survives an ordinary sync landing before the write runs",
       %{source: source} do
    assert :ok = sync(source, [cancelled_third()], "token-1")

    assert pending_moves() == [
             %{"original_start" => "2026-09-06T09:00:00Z", "new_start" => nil}
           ]

    # An ordinary sync of the same series — any later touch of any occurrence.
    # It carries no cancellation, because Google reports one only once.
    assert :ok = sync(source, [confirmed_last()], "token-2")

    # The correction must still be on the job. Losing it here is permanent:
    # nothing re-detects a cancellation, so the placeholder goes on blocking a
    # slot the organiser cleared.
    assert pending_moves() == [
             %{"original_start" => "2026-09-06T09:00:00Z", "new_start" => nil}
           ]
  end

  # Two cancellations in separate deltas. The second must not overwrite the
  # first, and the first must not suppress the second — both slots are cleared
  # and both need an EXDATE.
  test "a second cancellation joins the first rather than replacing it",
       %{source: source} do
    assert :ok = sync(source, [cancelled_third()], "token-1")

    second = google_delta_cancellation(@master_id, "2026-09-13T09:00:00Z")

    assert :ok = sync(source, [second], "token-2")

    assert pending_moves() == [
             %{"original_start" => "2026-09-06T09:00:00Z", "new_start" => nil},
             %{"original_start" => "2026-09-13T09:00:00Z", "new_start" => nil}
           ]
  end

  # The control. This one already worked live, and must keep working.
  test "a move survives the same sequence", %{source: source} do
    moved =
      google_delta_occurrence(@master_id, "20260913T090000Z", "2026-09-13T11:00:00Z",
        original_start: "2026-09-13T09:00:00Z"
      )

    assert :ok = sync(source, [moved], "token-1")

    assert pending_moves() == [
             %{
               "original_start" => "2026-09-13T09:00:00Z",
               "new_start" => "2026-09-13T11:00:00Z"
             }
           ]

    assert :ok = sync(source, [confirmed_last()], "token-2")

    assert pending_moves() == [
             %{
               "original_start" => "2026-09-13T09:00:00Z",
               "new_start" => "2026-09-13T11:00:00Z"
             }
           ]
  end
end
