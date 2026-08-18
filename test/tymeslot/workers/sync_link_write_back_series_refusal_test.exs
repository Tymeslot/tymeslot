defmodule Tymeslot.Workers.SyncLinkWriteBackSeriesRefusalTest do
  @moduledoc """
  The recurrence refusal as the write-back worker performs it, and the record it
  leaves behind.

  Split out of `SyncLinkWriteBackWorkerTest`, which is at the line budget the
  analyser enforces, and the seam is a real one: that module is about the
  discards, this is about the one discard that also has to *say something*.

  A recurring source is refused unless both ends of the link can carry it — the
  source able to have its series master fetched, the target able to expand the
  series it is handed. The refusal itself was correct before this module
  existed. What was missing is the two things asserted here: that the source
  half is asked at all, and that the refusal reaches somewhere an organiser can
  read it rather than stopping at an Oban discard reason.

  The provider mocks are set deliberately to *nothing*. `verify_on_exit!` turns
  any provider call into a failure, which is the assertion that the refusal
  lands before the master fetch: paying for a Google round trip to discover that
  the answer cannot be used would be a request per recurring event per sync, for
  nothing.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :sync_links

  import Mox
  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarSyncConflictQueries
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.SyncLinkWriteBackWorker

  setup :verify_on_exit!

  setup do
    # A process-independent ETS bucket that leaks between tests.
    RateLimiter.clear_all()
    linked_pair()
  end

  defp cached_event(source, attrs) do
    defaults = [
      calendar_integration: source,
      uid: "source-uid-1",
      summary: "Weekly standup",
      provider: source.provider,
      provider_event_id: "source-pid-1",
      all_day: false,
      start_at: ~U[2026-07-03 09:00:00Z],
      end_at: ~U[2026-07-03 10:00:00Z]
    ]

    insert(:provider_calendar_event, Keyword.merge(defaults, attrs))
  end

  defp args(link, source_uid, operation),
    do: %{
      "sync_link_id" => link.id,
      "source_uid" => source_uid,
      "operation" => operation
    }

  describe "an Outlook target, which cannot hold a series' cancellations" do
    # The cell this describes is refused for a reason Microsoft's API reference
    # states rather than one this codebase inferred, and the refusal is pinned
    # here because the alternative to pinning it is flipping it by accident.
    #
    # `patternedRecurrence` — the whole of what Graph's `recurrence` property
    # accepts — has exactly two properties, `pattern` and `range`. There is no
    # EXDATE analogue anywhere inside it, and none on the event body either:
    # Graph models a cancelled occurrence as a *separate* `exception`-type
    # event, and the master's `cancelledOccurrences` is documented as returned
    # only on a GET that `$select`s it, never accepted on a create.
    #
    # So the CalDAV fix cannot be repeated here. `Properties.build_exception_lines/1`
    # works because a VEVENT has somewhere to put an EXDATE line; a Graph
    # `recurrence` object does not. Honouring a cancellation on Outlook needs a
    # second API call per excluded occurrence, which is new write traffic with
    # new failure modes rather than a mapper change.
    #
    # Flipping this cell on the mapper alone would write a series whose cancelled
    # occurrences block the organiser's time forever, with the create answering
    # 201 and nothing retrying it — strictly worse than refusing.
    #
    # No provider expectation is set, and `verify_on_exit!` makes that an
    # assertion: the refusal must land before any Graph round trip is paid for.
    test "a recurring Google source is refused when the TARGET is Outlook", %{user: user} do
      google_source = insert(:calendar_integration, user: user, provider: "google")
      outlook_target = insert(:calendar_integration, user: user, provider: "outlook")

      link =
        insert(:calendar_sync_link,
          user_id: user.id,
          source_integration_id: google_source.id,
          target_integration_id: outlook_target.id
        )

      cached_event(google_source, google_series_markers())

      assert {:discard, :not_an_eligible_source} ==
               perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "upsert"))
    end

    # The discard is correct; its silence would not be. The organiser's remedy
    # here is to point the link at a calendar that can expand a series, and they
    # can only reach for it if the refusal is written down where they look.
    test "the refusal names the target as the end at fault", %{user: user} do
      google_source = insert(:calendar_integration, user: user, provider: "google")
      outlook_target = insert(:calendar_integration, user: user, provider: "outlook")

      link =
        insert(:calendar_sync_link,
          user_id: user.id,
          source_integration_id: google_source.id,
          target_integration_id: outlook_target.id
        )

      cached_event(google_source, google_series_markers())

      assert {:discard, :not_an_eligible_source} ==
               perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "upsert"))

      assert [conflict] =
               Map.get(CalendarSyncConflictQueries.list_for_links([link.id]), link.id, [])

      assert conflict.kind == "series_unsupported"
      assert conflict.source_uid == "source-uid-1"

      # "target", not "source" or "both": a Google source resolves its own
      # master perfectly well, so naming the source would send the organiser to
      # change the one end of the link that is working.
      assert conflict.detail["unsupported_end"] == "target"
      assert conflict.detail["target_provider"] == "outlook"
    end

    # An Outlook source *and* an Outlook target is the case where both halves
    # bite, and they bite for different reasons: the source resolves a master
    # but always with an empty exception list, and the target could not carry
    # the exceptions even if they arrived. `:series_lookup` is true for Outlook,
    # so this reports "target" — the honest answer for which end to change.
    test "an Outlook source onto an Outlook target still names the target", %{user: user} do
      outlook_source = insert(:calendar_integration, user: user, provider: "outlook")
      outlook_target = insert(:calendar_integration, user: user, provider: "outlook")

      link =
        insert(:calendar_sync_link,
          user_id: user.id,
          source_integration_id: outlook_source.id,
          target_integration_id: outlook_target.id
        )

      cached_event(outlook_source, google_series_markers() ++ [provider: "outlook"])

      assert {:discard, :not_an_eligible_source} ==
               perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "upsert"))

      assert [conflict] =
               Map.get(CalendarSyncConflictQueries.list_for_links([link.id]), link.id, [])

      assert conflict.detail["unsupported_end"] == "target"
    end

    # The counterpart that must keep working is asserted in
    # `EngineOutlookRecurrenceTest` rather than repeated here: an Outlook
    # calendar is a perfectly good *source* of a series onto a Google target,
    # and that path is pinned there on the payload the provider receives. It is
    # named because it is the reason this cell is refused rather than recurrence
    # being refused for Outlook at both ends — the source half is earned and
    # only the target half is not.
  end

  describe "a series neither end of the link can carry" do
    # The half the target-only gate missed. A source whose series master cannot
    # be fetched passed the old gate — the target expands a series, so the only
    # question asked answered yes — reached `RecurringSeries`, and came back
    # `{:skip, :provider_has_no_series_lookup}`. The job was discarded, no
    # placeholder was ever written and nothing retried it, so the organiser's
    # repeating meetings went on being bookable over with nothing said.
    #
    # The CalDAV family is what stands here now that Outlook resolves its own
    # masters, and it is the honest example rather than a substitute one: a
    # CalDAV row genuinely has no series to look up, because `ICalNormaliser`
    # expands the series locally into per-occurrence rows that carry no
    # `recurring_event_id` at all. The row below is given one anyway, which is
    # what makes this a test of the refusal rather than of the shape that never
    # reaches it.
    #
    # As with the target-side tests above, no provider expectation is set: the
    # refusal must land before any master fetch is attempted.
    test "a recurring source is refused when the SOURCE cannot resolve a series", %{user: user} do
      caldav_source = insert(:calendar_integration, user: user, provider: "nextcloud")
      google_target = insert(:calendar_integration, user: user, provider: "google")

      link =
        insert(:calendar_sync_link,
          user_id: user.id,
          source_integration_id: caldav_source.id,
          target_integration_id: google_target.id
        )

      cached_event(caldav_source, google_series_markers() ++ [provider: "nextcloud"])

      assert {:discard, :not_an_eligible_source} ==
               perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "upsert"))
    end

    test "and for every other member of the CalDAV family", %{user: user} do
      for provider <- ~w(caldav radicale apple baikal) do
        caldav_source = insert(:calendar_integration, user: user, provider: provider)
        google_target = insert(:calendar_integration, user: user, provider: "google")

        link =
          insert(:calendar_sync_link,
            user_id: user.id,
            source_integration_id: caldav_source.id,
            target_integration_id: google_target.id
          )

        cached_event(caldav_source, google_series_markers() ++ [provider: provider])

        assert {:discard, :not_an_eligible_source} ==
                 perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "upsert"))
      end
    end

    # The discard is correct and was never the defect; its silence was. This is
    # the assertion that the worker gives the refusal a voice on the way past —
    # without it the row is only ever written by a module nothing calls, which
    # is a feature that exists in the test suite and nowhere else.
    test "the refusal is recorded where the organiser can see it", %{user: user} do
      caldav_source = insert(:calendar_integration, user: user, provider: "nextcloud")
      google_target = insert(:calendar_integration, user: user, provider: "google")

      link =
        insert(:calendar_sync_link,
          user_id: user.id,
          source_integration_id: caldav_source.id,
          target_integration_id: google_target.id
        )

      cached_event(caldav_source, google_series_markers() ++ [provider: "nextcloud"])

      assert {:discard, :not_an_eligible_source} ==
               perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "upsert"))

      assert [conflict] =
               Map.get(CalendarSyncConflictQueries.list_for_links([link.id]), link.id, [])

      assert conflict.kind == "series_unsupported"
      assert conflict.source_uid == "source-uid-1"
      assert conflict.detail["unsupported_end"] == "source"
    end

    # An ordinary refusal must stay quiet. Transparency, cancellation and loop
    # prevention are not recurrence problems, and a row filed against one would
    # send the organiser hunting for a repeating event that does not exist.
    test "an ordinary refusal records no conflict", %{source: source, link: link} do
      cached_event(source, transparency: "transparent")

      assert {:discard, :not_an_eligible_source} ==
               perform_job(SyncLinkWriteBackWorker, args(link, "source-uid-1", "upsert"))

      assert CalendarSyncConflictQueries.list_for_links([link.id]) == %{}
    end
  end
end
