defmodule Tymeslot.Workers.SyncLinkWriteBackWorkerTest do
  @moduledoc """
  One mirror write, dispatched.

  The discards are what this module is mostly about. Every one of them is a
  condition under which no number of retries could ever succeed — a read-only
  target, a paused link, a link that has been deleted — and a job that keeps
  retrying against one of those burns provider quota until Oban gives up, on
  every event of every sync.

  The read-only case matters most and is asserted the hard way, by setting no
  provider expectation at all: `verify_on_exit!` turns any call into a failure,
  so the test fails if the worker so much as reaches for the provider before
  discarding. The changeset already refuses an ICS target at configuration time;
  this is the guard for the link created before a reconnect turned its target
  into a subscription.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :sync_links

  import Mox
  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.SyncLink.Engine
  alias Tymeslot.Integrations.Calendar.SyncLink.WriteBack
  alias Tymeslot.Workers.SyncLinkWriteBackWorker

  setup :verify_on_exit!

  setup do
    linked_pair()
  end

  defp cached_event(source, attrs \\ []) do
    defaults = [
      calendar_integration: source,
      uid: "source-uid-1",
      summary: "Board meeting",
      provider: source.provider,
      provider_event_id: "source-pid-1",
      all_day: false,
      start_at: ~U[2026-07-03 09:00:00Z],
      end_at: ~U[2026-07-03 10:00:00Z]
    ]

    insert(:provider_calendar_event, Keyword.merge(defaults, attrs))
  end

  defp args(link, source_uid, operation) do
    %{
      "sync_link_id" => link.id,
      "source_uid" => source_uid,
      "operation" => operation
    }
  end

  describe "perform/1 — upsert" do
    test "writes the placeholder and records the mapping", %{
      user: user,
      source: source,
      target: target,
      link: link
    } do
      cached_event(source)

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, context ->
        assert context == {target.id, user.id}
        assert event_data.summary == "Busy"
        {:ok, %{provider_event_id: "target-pid-1"}}
      end)

      assert :ok == perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "upsert"))

      assert {:ok, _mirror} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")
    end

    test "a provider failure is an error, so Oban retries it", %{source: source, link: link} do
      cached_event(source)

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:error, :rate_limited}
      end)

      assert {:error, :rate_limited} ==
               perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "upsert"))
    end
  end

  describe "perform/1 — discards before any provider call" do
    test "a read-only subscription target is refused", %{user: user, source: source} do
      ics_target = insert(:calendar_integration, user: user, provider: "ics_url")

      link =
        insert(:calendar_sync_link,
          user_id: user.id,
          source_integration_id: source.id,
          target_integration_id: ics_target.id
        )

      cached_event(source)

      assert {:discard, :target_is_read_only} ==
               perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "upsert"))
    end

    test "a paused link is refused", %{source: source, link: link} do
      {:ok, paused} = CalendarSyncLinkQueries.update(link, %{enabled: false})

      cached_event(source)

      assert {:discard, :link_disabled} ==
               perform_job(SyncLinkWriteBackWorker, args(paused, "source-uid-1", "upsert"))
    end

    test "a link deleted since the job was enqueued is refused", %{link: link} do
      assert {:discard, :link_not_found} ==
               perform_job(
                 SyncLinkWriteBackWorker,
                 args(%{link | id: link.id + 10_000}, "source-uid-1", "upsert")
               )
    end

    test "a source no longer in the cache is refused", %{link: link} do
      assert {:discard, :source_not_cached} ==
               perform_job(SyncLinkWriteBackWorker, args(link, "gone", "upsert"))
    end
  end

  describe "perform/1 — eligibility is re-checked at write time" do
    test "a source that became a mirror in the meantime never spawns a second",
         %{target: target, link: forward} = ctx do
      # The reverse link makes the pair bidirectional: the target is now also a
      # source, and the placeholder the forward link wrote onto it is exactly
      # what this job would mirror straight back.
      reverse = reverse_link(ctx)

      mirror_uid = Engine.target_uid_for(forward.id, "source-uid-1")
      mirror_for_link(forward, source_uid: "source-uid-1", target_uid: mirror_uid)

      insert(:provider_calendar_event,
        calendar_integration: target,
        uid: mirror_uid,
        summary: "Busy",
        provider: target.provider,
        provider_event_id: "target-pid-1"
      )

      assert {:discard, :not_an_eligible_source} ==
               perform_job(SyncLinkWriteBackWorker, args(reverse, mirror_uid, "upsert"))
    end

    test "a recurring source is refused", %{source: source, link: link} do
      cached_event(source, recurrence_rule: "FREQ=WEEKLY;COUNT=4")

      assert {:discard, :not_an_eligible_source} ==
               perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "upsert"))
    end

    test "a source that turned transparent has its placeholder withdrawn", %{
      source: source,
      link: link
    } do
      cached_event(source, transparency: "transparent")

      target_uid = Engine.target_uid_for(link.id, "source-uid-1")
      mirror_for_link(link, source_uid: "source-uid-1", target_uid: target_uid)

      expect(Tymeslot.CalendarMock, :delete_event, fn uid, _context ->
        assert uid == target_uid
        :ok
      end)

      assert :ok == perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "upsert"))

      assert {:error, :not_found} ==
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")
    end

    test "a transparent source with no placeholder yet never gets one", %{
      source: source,
      link: link
    } do
      cached_event(source, transparency: "transparent")

      # No provider expectation at all: `verify_on_exit!` fails the test if the
      # worker reaches for the target. A transparent event does not consume the
      # organiser's time, so a placeholder for it would block a slot that is
      # genuinely free.
      assert {:discard, :not_an_eligible_source} ==
               perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "upsert"))

      assert {:error, :not_found} ==
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")
    end

    test "transparency beats the privacy tier, including full_passthrough", %{
      source: source,
      link: link
    } do
      cached_event(source, transparency: "transparent")

      for tier <- ["busy_only", "generic_label", "full_passthrough"] do
        {:ok, tiered} =
          CalendarSyncLinkQueries.update(link, %{
            privacy_tier: tier,
            generic_label: "Personal commitment"
          })

        assert {:discard, :not_an_eligible_source} ==
                 perform_job(SyncLinkWriteBackWorker, args(tiered, "source-uid-1", "upsert"))

        assert {:error, :not_found} ==
                 CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")
      end
    end

    test "a placeholder written at one tier is withdrawn when its source turns transparent",
         %{source: source, link: link} do
      {:ok, link} = CalendarSyncLinkQueries.update(link, %{privacy_tier: "full_passthrough"})
      cached_event(source, summary: "Quarterly review with the board")

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        assert event_data.summary == "Quarterly review with the board"
        {:ok, %{provider_event_id: "target-pid-1"}}
      end)

      assert :ok == perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "upsert"))

      assert {:ok, _mirror} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")

      {:ok, event} = ProviderCalendarEventQueries.get_by_uid(source.id, "source-uid-1")

      {:ok, _transparent} =
        Repo.update(Changeset.change(event, transparency: "transparent"))

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context -> :ok end)

      assert :ok == perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "upsert"))

      assert {:error, :not_found} ==
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")
    end
  end

  describe "perform/1 — delete" do
    test "withdraws the placeholder for a source that is gone", %{link: link} do
      target_uid = Engine.target_uid_for(link.id, "source-uid-1")
      mirror_for_link(link, source_uid: "source-uid-1", target_uid: target_uid)

      expect(Tymeslot.CalendarMock, :delete_event, fn uid, _context ->
        assert uid == target_uid
        :ok
      end)

      assert :ok == perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "delete"))
    end

    test "a delete against a read-only target is discarded too", %{user: user, source: source} do
      ics_target = insert(:calendar_integration, user: user, provider: "ics_url")

      link =
        insert(:calendar_sync_link,
          user_id: user.id,
          source_integration_id: source.id,
          target_integration_id: ics_target.id
        )

      assert {:discard, :target_is_read_only} ==
               perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "delete"))
    end

    test "a delete does not require the source still to be cached", %{link: link} do
      target_uid = Engine.target_uid_for(link.id, "source-uid-1")
      mirror_for_link(link, source_uid: "source-uid-1", target_uid: target_uid)

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context -> :ok end)

      assert :ok == perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "delete"))
    end
  end

  describe "backoff/1" do
    # Oban's default backoff exhausts all five attempts inside about eighty
    # seconds. That suits a dropped connection and is exactly wrong for a
    # provider quota: Google meters per user over a rolling minute, so four
    # rapid retries mostly re-hit the same exhausted window and the write is
    # discarded permanently for a condition that was temporary. Observed in
    # production — a backlog of mirrors hit Google at once, every job answered
    # "Rate Limit Exceeded", and all of them were discarded within the minute.
    test "spreads the retries across minutes rather than seconds" do
      delays =
        for attempt <- 1..4, do: SyncLinkWriteBackWorker.backoff(%Oban.Job{attempt: attempt})

      assert Enum.all?(delays, &(&1 >= 60)),
             "every retry must clear a one-minute quota window, got #{inspect(delays)}"

      # Strictly increasing, so a target still refusing on the third attempt is
      # given longer than it was on the first.
      assert delays == Enum.sort(delays)
      assert Enum.uniq(delays) == delays
    end

    test "covers a quota window several times over before giving up" do
      total =
        Enum.sum(
          for attempt <- 1..4, do: SyncLinkWriteBackWorker.backoff(%Oban.Job{attempt: attempt})
        )

      assert total >= 600,
             "five attempts spanning #{total}s is too short to outlast a rate limit"
    end
  end

  describe "uniqueness" do
    test "a second enqueue for the same source collapses onto the pending job", %{link: link} do
      :ok = WriteBack.enqueue(link.id, "source-uid-1", :upsert)
      :ok = WriteBack.enqueue(link.id, "source-uid-1", :upsert)

      assert [_only_one] = all_enqueued(worker: SyncLinkWriteBackWorker)
    end

    test "a delete replaces the pending upsert's args rather than being dropped", %{link: link} do
      :ok = WriteBack.enqueue(link.id, "source-uid-1", :upsert)
      :ok = WriteBack.enqueue(link.id, "source-uid-1", :delete)

      assert [job] = all_enqueued(worker: SyncLinkWriteBackWorker)
      assert job.args["operation"] == "delete"
    end

    test "different source events get their own jobs", %{link: link} do
      :ok = WriteBack.enqueue(link.id, "source-uid-1", :upsert)
      :ok = WriteBack.enqueue(link.id, "source-uid-2", :upsert)

      assert length(all_enqueued(worker: SyncLinkWriteBackWorker)) == 2
    end
  end
end
