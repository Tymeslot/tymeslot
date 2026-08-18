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

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.SyncLink.Engine
  alias Tymeslot.Integrations.Calendar.SyncLink.WriteBack
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.SyncLinkWriteBackWorker

  setup :verify_on_exit!

  setup do
    # The write budget is a process-independent ETS bucket and leaks between
    # tests: without this, a test that spends it fails the next one for a
    # reason that has nothing to do with what it asserts.
    RateLimiter.clear_all()
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
        oauth_write_response("target-pid-1")
      end)

      assert :ok == perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "upsert"))

      assert {:ok, mirror} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")

      # The id the provider filed the placeholder under, off the write response.
      # A mapping recording `nil` here looks active and names nothing, which is
      # the state 420 live rows were in.
      assert mirror.target_provider_event_id == "target-pid-1"
    end

    test "a provider failure is an error, so Oban retries it", %{source: source, link: link} do
      cached_event(source)

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:error, :network_error}
      end)

      assert {:error, :network_error} ==
               perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "upsert"))
    end

    # A rate limit is not this job's failure. It says the *account* is over
    # quota, which every other job writing to the same calendar is about to
    # discover too, and burning an attempt on it means a backlog of fifty
    # mirrors exhausts five attempts each and discards them all — for a
    # condition that clears in a minute.
    #
    # A snooze reschedules without consuming an attempt, so the write survives
    # a burst however long the burst lasts.
    test "a rate limit snoozes rather than spending an attempt", %{source: source, link: link} do
      cached_event(source)

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:error, :rate_limited}
      end)

      assert {:snooze, seconds} =
               perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "upsert"))

      assert seconds >= 60, "a snooze shorter than the quota window just re-hits it"
    end

    # The snooze above is reactive: the burst still reaches Google and is still
    # refused, it just survives the refusal. This is the proactive half — the
    # write is not attempted at all once the target account's own budget for
    # the second is spent, so the burst never leaves the machine.
    #
    # Keyed on the target integration because the quota Google enforces is
    # per-account: two organisers mirroring at once must not share a budget,
    # and two links onto the same calendar must.
    test "stops writing once the target account's budget for the second is spent", ctx do
      %{source: source, link: link} = ctx

      # The budget is what bounds the provider calls, so the mock is told to
      # accept any number: the assertion is that far fewer than twelve arrive.
      stub(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        oauth_write_response("target-pid")
      end)

      outcomes =
        for n <- 1..12 do
          cached_event(source, uid: "source-uid-#{n}", provider_event_id: "source-pid-#{n}")
          perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-#{n}", "upsert"))
        end

      written = Enum.count(outcomes, &(&1 == :ok))
      paced = Enum.count(outcomes, &match?({:snooze, _seconds}, &1))

      assert paced > 0,
             "the budget never ran out, so nothing paced the burst: #{inspect(outcomes)}"

      # Some writes must still get through — a gate that refused everything
      # would pace the burst by never mirroring at all.
      assert written > 0
      assert written < 12, "all twelve reached the provider, so the budget did nothing"
    end

    # Every job in a backlog is refused at almost the same instant, so a fixed
    # snooze would reschedule them all to the same second and rebuild the burst
    # that caused the refusal. Spreading them is what actually drains the queue.
    test "snoozes are spread rather than landing together", %{source: source, link: link} do
      cached_event(source)

      # Refused by the provider rather than by the local budget, so this
      # exercises the snooze itself. `stub` because the budget decides how many
      # calls actually get through.
      stub(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:error, :rate_limited}
      end)

      delays =
        for _attempt <- 1..40 do
          {:snooze, seconds} =
            perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "upsert"))

          seconds
        end

      assert length(Enum.uniq(delays)) > 1,
             "every job snoozed for #{inspect(hd(delays))}s, which re-creates the burst"
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

    # Teardown disables the link *before* withdrawing its placeholders, so a
    # provider that refused a delete leaves exactly this state: a disabled link
    # holding `pending_delete` rows. `SyncLinkReconcileWorker.finish_withdrawals/1`
    # re-enqueues those deletes every sweep for that reason — discarding them
    # here strands the placeholder for good, and the row with it, because
    # nothing else ever revisits a `pending_delete` mapping.
    test "a paused link still finishes a withdrawal teardown left behind", %{
      source: source,
      link: link
    } do
      {:ok, paused} = CalendarSyncLinkQueries.update(link, %{enabled: false})

      mirror_for_link(paused, source_uid: "source-uid-1", state: "pending_delete")
      cached_event(source)

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

      assert :ok ==
               perform_job(SyncLinkWriteBackWorker, args(paused, "source-uid-1", "delete"))

      assert {:error, :not_found} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(paused.id, "source-uid-1")
    end

    # A provider that refuses the request as written refuses it identically on
    # every retry. Left as an error it burned all five attempts across twenty
    # minutes, then the reconcile sweep re-derived the same write and started
    # again — and marked the target unhealthy on the way, for a payload fault
    # that says nothing about the target's health.
    test "a payload the provider rejects is discarded rather than retried", %{
      source: source,
      link: link
    } do
      cached_event(source)

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:error, :invalid_request}
      end)

      assert {:discard, :invalid_request} ==
               perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "upsert"))
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

    test "a recurring source is refused when the target cannot expand a series", %{
      user: user,
      source: source
    } do
      outlook_target = insert(:calendar_integration, user: user, provider: "outlook")

      link =
        insert(:calendar_sync_link,
          user_id: user.id,
          source_integration_id: source.id,
          target_integration_id: outlook_target.id
        )

      cached_event(source, google_series_markers())

      # No provider expectation of any kind, and that is the assertion: the
      # refusal must come before the master fetch as well as before the write.
      # Paying for a Google request to discover that Outlook cannot take the
      # answer would be a round trip per recurring event per sync, for nothing.
      assert {:discard, :not_an_eligible_source} ==
               perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "upsert"))
    end

    # The CalDAV counterpart used to assert the same discard as Outlook above,
    # and no longer can: a CalDAV target expands a series, verified against a
    # live Radicale which stored the RRULE and the EXDATE beside it and dropped
    # the cancelled occurrence from its own expansion. So the job runs through
    # to the write, and the master fetch that the Outlook case must *not* make
    # is exactly the one this case must.
    test "but a CalDAV target is mirrored through, master fetch and all", %{
      user: user,
      source: source
    } do
      caldav_target = insert(:calendar_integration, user: user, provider: "nextcloud")

      link =
        insert(:calendar_sync_link,
          user_id: user.id,
          source_integration_id: source.id,
          target_integration_id: caldav_target.id
        )

      cached_event(source, google_series_markers())

      expect(GoogleCalendarAPIMock, :get_event, fn _integration, _calendar_id, event_id ->
        assert event_id == "master_abc123"

        {:ok,
         %{
           "recurrence" => [
             "RRULE:FREQ=WEEKLY;COUNT=5",
             "EXDATE;TZID=Europe/Tallinn:20260915T120000"
           ]
         }}
      end)

      test_pid = self()

      # `{:ok, uid}` — a bare string, which is what a CalDAV create answers.
      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        {:ok, event_data.uid}
      end)

      assert :ok == perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "upsert"))

      assert_received {:payload, payload}
      assert payload.recurrence_rule == "RRULE:FREQ=WEEKLY;COUNT=5"

      assert payload.recurrence_exception_lines == [
               "EXDATE;TZID=Europe/Tallinn:20260915T120000"
             ]
    end

    test "a recurring source IS mirrored when the target expands a series", %{
      source: source,
      link: link
    } do
      cached_event(source, google_series_markers())

      expect(GoogleCalendarAPIMock, :get_event, fn _integration, _calendar_id, event_id ->
        assert event_id == "master_abc123"
        {:ok, %{"recurrence" => ["RRULE:FREQ=WEEKLY;COUNT=52"]}}
      end)

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        oauth_write_response("target-pid-1")
      end)

      assert :ok == perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "upsert"))

      assert_received {:payload, payload}
      assert payload.recurrence_rule == "RRULE:FREQ=WEEKLY;COUNT=52"

      assert {:ok, _mirror} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")
    end

    # The withdrawal half of the enqueue-then-refuse routing. A source that has
    # become recurring on a link whose target cannot take one leaves a
    # placeholder describing a single occurrence, which must come down rather
    # than sit there blocking a slot the organiser now recurs through. This is
    # why the worker routes the refusal through `unmirror_or_discard/4` instead
    # of discarding outright.
    test "a source that became recurring has its stale placeholder withdrawn", %{
      user: user,
      source: source
    } do
      outlook_target = insert(:calendar_integration, user: user, provider: "outlook")

      link =
        insert(:calendar_sync_link,
          user_id: user.id,
          source_integration_id: source.id,
          target_integration_id: outlook_target.id
        )

      cached_event(source, google_series_markers())

      target_uid = Engine.target_uid_for(link.id, "source-uid-1")
      mirror_for_link(link, source_uid: "source-uid-1", target_uid: target_uid)

      expect(Tymeslot.CalendarMock, :delete_event, fn uid, _context, _opts ->
        assert uid == target_uid
        :ok
      end)

      assert :ok == perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "upsert"))

      assert {:error, :not_found} ==
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")
    end

    test "a source that turned transparent has its placeholder withdrawn", %{
      source: source,
      link: link
    } do
      cached_event(source, transparency: "transparent")

      target_uid = Engine.target_uid_for(link.id, "source-uid-1")
      mirror_for_link(link, source_uid: "source-uid-1", target_uid: target_uid)

      expect(Tymeslot.CalendarMock, :delete_event, fn uid, _context, _opts ->
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
        oauth_write_response("target-pid-1")
      end)

      assert :ok == perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "upsert"))

      assert {:ok, _mirror} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")

      {:ok, event} = ProviderCalendarEventQueries.get_by_uid(source.id, "source-uid-1")

      {:ok, _transparent} =
        Repo.update(Changeset.change(event, transparency: "transparent"))

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

      assert :ok == perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "upsert"))

      assert {:error, :not_found} ==
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, "source-uid-1")
    end
  end

  describe "perform/1 — delete" do
    test "withdraws the placeholder for a source that is gone", %{link: link} do
      target_uid = Engine.target_uid_for(link.id, "source-uid-1")
      mirror_for_link(link, source_uid: "source-uid-1", target_uid: target_uid)

      expect(Tymeslot.CalendarMock, :delete_event, fn uid, _context, _opts ->
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

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

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

    test "a running job's args are left alone", %{link: link} do
      # Replacing a *pending* job's args is the point of `replace`: the newer
      # intent should win before anything runs. Replacing an *executing* one is
      # a different thing — `perform/1` has already read its args, so the
      # rewrite changes nothing it will do while making the job's record
      # disagree with what it is actually performing.
      #
      # The write that arrives mid-run is dropped by uniqueness rather than
      # deferred, which is the accepted trade: `:executing` has to stay in the
      # window or two jobs could run concurrently for one event, and
      # `SyncLinkReconcileWorker` re-derives a lost delete on the next sweep.
      :ok = WriteBack.enqueue(link.id, "source-uid-1", :upsert)

      [running] = all_enqueued(worker: SyncLinkWriteBackWorker)

      {1, _returned} =
        Repo.update_all(from(j in Oban.Job, where: j.id == ^running.id),
          set: [state: "executing", attempted_at: DateTime.utc_now()]
        )

      :ok = WriteBack.enqueue(link.id, "source-uid-1", :delete)

      executing = Repo.one(from(j in Oban.Job, where: j.id == ^running.id))

      assert executing.state == "executing"
      assert executing.args["operation"] == "upsert"
    end
  end
end
