defmodule Tymeslot.Integrations.Calendar.SyncLink.WriteBackExecutingConflictTest do
  @moduledoc """
  An intent raised while the write-back job for the same placeholder is running.

  ## What Oban actually does, measured rather than assumed

  The worker's uniqueness window includes `:executing`, and the enqueue site's
  `replace` deliberately names only the pending states. Both halves are right on
  their own, and the pairing had a hole nobody had put under test.

  An enqueue arriving mid-run matches the *executing* job as its conflict.
  Oban 2.23's `Basic.resolve_conflict/4` looks the conflicting job's state up in
  the `replace` keyword — `Keyword.get(replace, :executing, [])` — takes no
  fields, and returns the existing row with `conflict?: true`. Observed against
  the real insert path: **one job in the table, args unchanged, nothing
  inserted**. The newer intent is not deferred behind the running job the way
  `WriteBack`'s moduledoc used to claim; it is dropped.

  Two consequences, and they are not equally survivable:

  - a `delete` is dropped, so a placeholder is written for an event the
    organiser has already deleted. `SyncLinkReconcileWorker` re-derives this one
    from state — a mapping whose source is absent from the cache — so it costs a
    sweep, not the placeholder.
  - a **cancellation correction** is dropped, and nothing recovers it. Google
    reports a cancelled occurrence in exactly one delta and omits it from every
    later one, and the sweep's `moved: :preserve` reads *pending jobs*, of which
    there is now none carrying the EXDATE. The placeholder goes on blocking a
    slot the organiser cleared, permanently.

  The fix re-inserts the intent as its own job, scheduled past the running one,
  under a uniqueness window narrowed to the pending states. These tests pin the
  observable end of that: a second job exists, it is `scheduled` rather than
  `available`, and it carries the intent that was being dropped.

  The narrowing is load-bearing and has its own test. `unique: false` preserves
  the intent and loses the collapsing — one sync enqueues for the same pair
  twice, via `MovedOccurrence.report/2` and then `enqueue_mirror_write_backs/3`,
  so a cancellation sync landing mid-run produced *two* follow-ups, one carrying
  the correction and one not. `WriteBackQueries.pending_moves/2` applies
  `limit(1)` with no ordering, so it then read whichever row Postgres happened
  to return and the correction became a coin toss. Measured: it came back `nil`.

  ## Why the ordinary sync path drives half of them

  The hand-forced state transition proves the mechanism; it does not prove the
  ordering is reachable. The cancellation tests therefore run two real Google
  deltas through `SyncGoogleCalendarWorker` with the write-back job forced
  executing between them, which is the production sequence exactly: a sync lands
  while the queue is draining a previous one.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :sync_links
  @moduletag :workers

  import Ecto.Query
  import Mox
  import Tymeslot.Factory
  import Tymeslot.GoogleDeltaFixtures
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.SyncLink.WriteBack
  alias Tymeslot.Integrations.Calendar.SyncLink.WriteBackQueries
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  setup :verify_on_exit!

  @worker "Tymeslot.Workers.SyncLinkWriteBackWorker"

  @moves [%{"original_start" => "2026-08-14T14:00:00Z", "new_start" => "2026-08-14T22:00:00Z"}]

  defp write_back_jobs do
    Oban.Job
    |> where([j], j.worker == @worker)
    |> order_by([j], asc: j.id)
    |> Repo.all()
  end

  # The queue picking a job up. Oban's testing mode is `:manual`, so no queue is
  # draining and the transition has to be made rather than waited for — but the
  # row it produces is the row a running job has.
  defp mark_executing(%Oban.Job{id: id}) do
    {1, _updated} =
      Oban.Job
      |> where([j], j.id == ^id)
      |> Repo.update_all(set: [state: "executing", attempted_at: DateTime.utc_now()])

    :ok
  end

  describe "an intent raised while the write-back for the same placeholder runs" do
    setup do: linked_pair()

    test "a delete is inserted as its own job rather than dropped", %{link: link} do
      assert :ok = WriteBack.enqueue(link.id, "series-uid", :upsert)
      assert [running] = write_back_jobs()
      assert :ok = mark_executing(running)

      assert :ok = WriteBack.enqueue(link.id, "series-uid", :delete)

      jobs = write_back_jobs()

      assert length(jobs) == 2,
             "the delete was dropped; #{length(jobs)} job(s) exist, states #{inspect(Enum.map(jobs, & &1.state))}"

      assert [still_running, follow_up] = jobs
      assert still_running.id == running.id
      assert still_running.args["operation"] == "upsert"
      assert follow_up.args["operation"] == "delete"
    end

    test "the follow-up is scheduled past the running job, not made available",
         %{link: link} do
      # The whole reason uniqueness may be bypassed here. An `available`
      # follow-up could be picked up beside the job that is still writing the
      # same placeholder, which is the two-writer race `Engine`'s moduledoc
      # documents and uniqueness exists to prevent.
      assert :ok = WriteBack.enqueue(link.id, "series-uid", :upsert)
      assert [running] = write_back_jobs()
      assert :ok = mark_executing(running)

      assert :ok = WriteBack.enqueue(link.id, "series-uid", :delete)

      assert [_running, follow_up] = write_back_jobs()
      assert follow_up.state == "scheduled"
      assert DateTime.compare(follow_up.scheduled_at, DateTime.utc_now()) == :gt
    end

    test "the deferred job carries the moves the dropped enqueue was raising",
         %{link: link} do
      assert :ok = WriteBack.enqueue(link.id, "series-uid", :upsert)
      assert [running] = write_back_jobs()
      assert :ok = mark_executing(running)

      assert :ok = WriteBack.enqueue(link.id, "series-uid", :upsert, moved: @moves)

      assert [_running, follow_up] = write_back_jobs()
      assert follow_up.args["moved"] == @moves
    end

    test "repeated enqueues during one run collapse onto a single deferred job",
         %{link: link} do
      # The reason the follow-up narrows its uniqueness window instead of
      # disabling it. One sync enqueues for the same pair more than once —
      # `MovedOccurrence.report/2` and then `enqueue_mirror_write_backs/3` — and
      # with uniqueness off every one of them inserts its own follow-up. Two
      # deferred jobs for one pair is the state `pending_moves/2`' unordered
      # `limit(1)` cannot read correctly, so the correction becomes a coin toss.
      assert :ok = WriteBack.enqueue(link.id, "series-uid", :upsert)
      assert [running] = write_back_jobs()
      assert :ok = mark_executing(running)

      assert :ok = WriteBack.enqueue(link.id, "series-uid", :upsert)
      assert :ok = WriteBack.enqueue(link.id, "series-uid", :upsert, moved: @moves)
      assert :ok = WriteBack.enqueue(link.id, "series-uid", :delete)

      jobs = write_back_jobs()

      assert length(jobs) == 2,
             "expected the running job and exactly one deferred follow-up, got #{length(jobs)}"

      assert [_running, follow_up] = jobs

      # `replace` rewrote the deferred job's args each time, so it carries the
      # last intent rather than the first — the same rule the ordinary path has.
      assert follow_up.args["operation"] == "delete"
    end

    test "a conflict against a pending job still collapses onto it", %{link: link} do
      # The control. `replace` names the pending states, so the intent is
      # carried by rewriting the args and a second job would be wrong — the
      # collapsing behaviour the queue is built on must not have been traded
      # away to fix the executing case.
      assert :ok = WriteBack.enqueue(link.id, "series-uid", :upsert)
      assert :ok = WriteBack.enqueue(link.id, "series-uid", :delete)

      assert [only] = write_back_jobs()
      assert only.state == "available"
      assert only.args["operation"] == "delete"
    end
  end

  describe "one source event on three links" do
    setup do
      ctx = linked_pair()
      {_target_b, link_b} = extra_target_link(ctx)
      {_target_c, link_c} = extra_target_link(ctx)

      Map.merge(ctx, %{link_b: link_b, link_c: link_c})
    end

    test "each link gets its own job and reads only its own moves",
         %{link: link_a, link_b: link_b, link_c: link_c} do
      # Uniqueness is keyed on `[:sync_link_id, :source_uid]`, so three links
      # mirroring one source event are three separate keys and three separate
      # jobs. `pending_moves/2` applies `limit(1)` with no ordering, which is
      # only safe because the `sync_link_id` filter has already reduced the set
      # to one row — this is what pins that it has.
      assert :ok = WriteBack.enqueue(link_a.id, "shared-uid", :upsert)
      assert :ok = WriteBack.enqueue(link_b.id, "shared-uid", :upsert, moved: @moves)
      assert :ok = WriteBack.enqueue(link_c.id, "shared-uid", :upsert)

      jobs = write_back_jobs()
      assert length(jobs) == 3, "expected one job per link, got #{length(jobs)}"

      assert WriteBackQueries.pending_moves(link_b.id, "shared-uid") == @moves

      # The link carrying no correction must not pick up its neighbour's.
      assert WriteBackQueries.pending_moves(link_a.id, "shared-uid") == nil
      assert WriteBackQueries.pending_moves(link_c.id, "shared-uid") == nil
    end

    test "a delete on one link leaves the other two upserting",
         %{link: link_a, link_b: link_b, link_c: link_c} do
      assert :ok = WriteBack.enqueue(link_a.id, "shared-uid", :upsert)
      assert :ok = WriteBack.enqueue(link_b.id, "shared-uid", :upsert)
      assert :ok = WriteBack.enqueue(link_c.id, "shared-uid", :upsert)

      assert :ok = WriteBack.enqueue(link_b.id, "shared-uid", :delete)

      by_link = Map.new(write_back_jobs(), &{&1.args["sync_link_id"], &1.args["operation"]})

      assert by_link == %{
               link_a.id => "upsert",
               link_b.id => "delete",
               link_c.id => "upsert"
             }
    end
  end

  describe "the production ordering: a sync landing while the queue drains" do
    @master_id "lvis2ao68dlbl2j92k861eqr30"
    @series_uid "lvis2ao68dlbl2j92k861eqr30@google.com"

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

    defp sync(source, events, token) do
      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:ok, %{events: events, next_sync_token: token}}
      end)

      perform_job(SyncGoogleCalendarWorker, %{"calendar_integration_id" => source.id})
    end

    test "a cancellation detected while a plain upsert runs is not lost",
         %{source: source} do
      # The permanent one. An ordinary occurrence syncs and its write-back job
      # is picked up; the *next* delta is the only one that will ever report the
      # cancellation. If that enqueue is dropped, no later sync re-detects it and
      # the placeholder blocks the cleared slot for the life of the series.
      confirmed =
        google_delta_occurrence(@master_id, "20260920T090000Z", "2026-09-20T09:00:00Z")

      assert :ok = sync(source, [confirmed], "token-1")
      assert [running] = write_back_jobs()
      assert :ok = mark_executing(running)

      cancelled = google_delta_cancellation(@master_id, "2026-09-06T09:00:00Z")

      assert :ok = sync(source, [cancelled], "token-2")

      jobs = write_back_jobs()

      assert length(jobs) == 2,
             "the cancellation was dropped; #{length(jobs)} job(s), moved #{inspect(Enum.map(jobs, & &1.args["moved"]))}"

      assert [_running, follow_up] = jobs

      assert follow_up.args["moved"] == [
               %{"original_start" => "2026-09-06T09:00:00Z", "new_start" => nil}
             ]
    end

    test "the deferred cancellation is still readable as a pending move",
         %{source: source} do
      # `moved: :preserve` is how `SyncLinkReconcileWorker` and `Remirror` avoid
      # destroying a correction while repairing the thing it corrects. A
      # correction parked on a scheduled follow-up has to remain visible to that
      # lookup, or the sweep that runs before it does would wipe it.
      confirmed =
        google_delta_occurrence(@master_id, "20260920T090000Z", "2026-09-20T09:00:00Z")

      assert :ok = sync(source, [confirmed], "token-1")
      assert [running] = write_back_jobs()
      assert :ok = mark_executing(running)

      cancelled = google_delta_cancellation(@master_id, "2026-09-06T09:00:00Z")

      assert :ok = sync(source, [cancelled], "token-2")

      assert WriteBackQueries.pending_moves(running.args["sync_link_id"], @series_uid) == [
               %{"original_start" => "2026-09-06T09:00:00Z", "new_start" => nil}
             ]
    end
  end
end
