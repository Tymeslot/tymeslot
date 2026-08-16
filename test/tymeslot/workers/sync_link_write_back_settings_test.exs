defmodule Tymeslot.Workers.SyncLinkWriteBackSettingsTest do
  @moduledoc """
  A settings change that lands while a write is already queued is honoured by
  that write.

  The job args carry `sync_link_id`, `source_uid` and `operation` — never the
  link's presentation — and `perform/1` re-reads the row through
  `CalendarSyncLinkQueries.get/1` when it runs. So the payload is built from the
  link as it stands at write time, and an organiser who changes a tier while a
  backlog is draining sees the new tier on the placeholders that backlog writes,
  not the old one.

  ## Why this needs pinning

  The refactor that breaks it looks like an optimisation: stash the tier and the
  label into the job args at enqueue time and save a database read per write.
  Nothing would fail. The placeholder would carry the presentation the link had
  when the job was inserted, the row would say something else, and no mechanism
  compares the two — `SyncLinkReconcileWorker` diffs the source event's
  timestamp against the mapping's, and the link is not an input to either. The
  organiser sees their setting stored and their calendar disagreeing with it,
  with nothing to say why.

  The nearest existing tests prove the *source event* is re-read at perform
  time. That is a different window and a different guard.

  ## Asserted on the payload, not on the row

  What is stored is not the feature; what the target calendar ends up saying is.
  A test asserting only that the link row holds the new tier passes in exactly
  the world this module exists to rule out, so both tests here capture the map
  handed to `create_event/2` and assert on its `:summary`.

  Both directions are covered, and the tightening one is the sharper of the two:
  a stale payload there discloses a title the organiser has just asked to stop
  disclosing.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :sync_links

  import Mox
  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.SyncLink.WriteBack
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.SyncLinkWriteBackWorker

  setup :verify_on_exit!

  setup do
    # The write budget is a process-independent ETS bucket and leaks between
    # tests: without this, a test that spends it fails the next one for a reason
    # that has nothing to do with what it asserts.
    RateLimiter.clear_all()
    linked_pair()
  end

  defp cached_event(source, summary) do
    insert(:provider_calendar_event,
      calendar_integration: source,
      uid: "source-uid-1",
      summary: summary,
      provider: source.provider,
      provider_event_id: "source-pid-1",
      all_day: false,
      start_at: ~U[2026-07-03 09:00:00Z],
      end_at: ~U[2026-07-03 10:00:00Z]
    )
  end

  # The payload the provider was actually handed, captured out of the mock.
  defp capture_payload do
    test_pid = self()

    expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
      send(test_pid, {:payload, event_data})
      {:ok, %{provider_event_id: "target-pid-1"}}
    end)
  end

  describe "perform/1 — the link is read at perform time" do
    test "a tier changed after the job was enqueued is what reaches the provider", %{
      source: source,
      link: link
    } do
      cached_event(source, "Quarterly review with the board")

      # Enqueued while the link is still at its default `busy_only`. The job's
      # args are read back rather than reconstructed, so the test exercises the
      # payload the enqueue site actually writes.
      :ok = WriteBack.enqueue(link.id, "source-uid-1", :upsert)
      assert [job] = all_enqueued(worker: SyncLinkWriteBackWorker)

      {:ok, _relabelled} =
        CalendarSyncLinkQueries.update(link, %{
          privacy_tier: "generic_label",
          generic_label: "Personal commitment"
        })

      capture_payload()

      assert :ok == perform_job(SyncLinkWriteBackWorker, job.args)

      assert_received {:payload, payload}

      assert payload.summary == "Personal commitment",
             "the write used the link as it was at enqueue time, not as it is now"
    end

    test "a tier tightened after the job was enqueued stops disclosing the summary", %{
      source: source,
      link: link
    } do
      {:ok, open} = CalendarSyncLinkQueries.update(link, %{privacy_tier: "full_passthrough"})

      cached_event(source, "Quarterly review with the board")

      :ok = WriteBack.enqueue(open.id, "source-uid-1", :upsert)
      assert [job] = all_enqueued(worker: SyncLinkWriteBackWorker)

      {:ok, _tightened} = CalendarSyncLinkQueries.update(open, %{privacy_tier: "busy_only"})

      capture_payload()

      assert :ok == perform_job(SyncLinkWriteBackWorker, job.args)

      assert_received {:payload, payload}

      assert payload.summary == "Busy",
             "a tier tightened between enqueue and perform still leaked the source summary"
    end
  end
end
