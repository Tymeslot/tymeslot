defmodule Tymeslot.Integrations.Calendar.SyncLink.EngineCaldavRecurrenceTest do
  @moduledoc """
  A recurring CalDAV source needs no series machinery, and must not be given
  any.

  This file exists because the obvious reading of the CalDAV path is wrong in a
  way that would be expensive. A cached CalDAV row *does* carry a
  `recurrence_rule` — unlike Google's and Outlook's, which carry none — and the
  natural conclusion is that CalDAV is the easy provider: the rule is already
  here, so hand it to the target and skip the master fetch entirely.

  Doing that would write one whole series per occurrence.

  `ICalNormaliser` expands a CalDAV series **locally**, before anything is
  cached. `expand_event/3` emits one raw map per occurrence; `build_uid/1`
  gives each its own uid (`"<master UID>_<occurrence stamp>"`), so
  `upsert_batch/1` never collapses the series into a single row the way it does
  for the other two providers; and `resolve_timing/1` times each row from its
  own `_occ_start` rather than from the master's DTSTART. What it does copy onto
  every occurrence is the master's RRULE.

  So a fifty-occurrence CalDAV series is fifty correctly-timed, uniquely-keyed
  cache rows that each happen to carry the series' rule. Each is already the
  one-off the mirror path should write. Forwarding the rule would turn each of
  the fifty into a placeholder describing the *whole series* starting at that
  occurrence — fifty overlapping infinite series where fifty single blocks
  belong.

  The tests below therefore assert an absence as their central claim: no rule on
  the payload, no master fetch, and the occurrence's own times. An absence is
  worth asserting here precisely because the wrong version is the one that looks
  more finished.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :sync_links

  import Mox
  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries
  alias Tymeslot.Integrations.Calendar.SyncLink.Engine

  setup :verify_on_exit!

  setup do
    user = insert(:user)
    source = insert(:calendar_integration, user: user, provider: "nextcloud")
    target = insert(:calendar_integration, user: user, provider: "google")

    link =
      insert(:calendar_sync_link,
        user_id: user.id,
        source_integration_id: source.id,
        target_integration_id: target.id
      )

    {:ok, link} = CalendarSyncLinkQueries.get(link.id)

    %{user: user, source: source, target: target, link: link}
  end

  describe "an expanded CalDAV occurrence mirrors as the one-off it already is" do
    test "the placeholder carries the occurrence's own times and no rule at all", %{
      user: user,
      source: source,
      link: link
    } do
      # No `expect` for any master fetch on either API mock: a CalDAV row has
      # nothing to look up, and a call would fail `verify_on_exit!`.
      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        oauth_write_response("target-pid-1")
      end)

      occurrence = caldav_series_occurrence(source)

      assert occurrence.recurrence_rule == "FREQ=WEEKLY;BYDAY=TU",
             "the row really does carry the master's rule — that is the trap"

      assert occurrence.recurring_event_id == nil,
             "and it carries no master handle, so there is nothing to fetch"

      assert :ok == Engine.mirror(link, occurrence, user.id)

      assert_received {:payload, payload}

      # THE assertion. A rule here would describe a whole series beginning at
      # this occurrence, and there would be one such placeholder for every
      # occurrence of the series.
      refute Map.has_key?(payload, :recurrence_rule),
             "an expanded occurrence must not be mirrored as a series"

      refute Map.has_key?(payload, :recurrence_exception_lines)

      # Its own times, which are already correct: `resolve_timing/1` times an
      # expanded row from its occurrence, not from the master's DTSTART.
      assert payload.start_time == ~U[2026-03-10 09:00:00Z]
      assert payload.end_time == ~U[2026-03-10 09:30:00Z]

      assert payload.summary == "Busy"
      assert payload.transparency == :opaque
    end

    test "each occurrence of the series is its own placeholder and its own mirror row", %{
      user: user,
      source: source,
      link: link
    } do
      # Three occurrences of one weekly series, as the cache actually holds
      # them: distinct uids, distinct times, the same rule copied onto each.
      # This is the shape that makes the rule dangerous — mirroring it would
      # produce three overlapping infinite series.
      occurrences =
        for start <- [
              ~U[2026-03-10 09:00:00Z],
              ~U[2026-03-17 09:00:00Z],
              ~U[2026-03-24 09:00:00Z]
            ] do
          caldav_series_occurrence(source, %{occurrence_start: start})
        end

      assert length(Enum.uniq_by(occurrences, & &1.uid)) == 3,
             "each expanded occurrence has its own uid — the cache does not dedupe them"

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, 3, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        oauth_write_response("target-pid-#{event_data.start_time}")
      end)

      for occurrence <- occurrences do
        assert :ok == Engine.mirror(link, occurrence, user.id)
      end

      payloads =
        for _occurrence <- 1..3 do
          assert_received {:payload, payload}
          payload
        end

      # Every one a plain block at its own time. Not one of them a series.
      for payload <- payloads do
        refute Map.has_key?(payload, :recurrence_rule)
      end

      assert Enum.map(payloads, & &1.start_time) == [
               ~U[2026-03-10 09:00:00Z],
               ~U[2026-03-17 09:00:00Z],
               ~U[2026-03-24 09:00:00Z]
             ]

      assert length(CalendarSyncMirrorQueries.list_for_link(link.id)) == 3
    end

    test "an all-day CalDAV occurrence keeps its Date timing and stays ruleless", %{
      user: user,
      source: source,
      link: link
    } do
      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        oauth_write_response("target-pid-1")
      end)

      occurrence =
        caldav_series_occurrence(source, %{
          all_day: true,
          start_at: nil,
          end_at: nil,
          start_date: ~D[2026-03-10],
          end_date: ~D[2026-03-11]
        })

      assert :ok == Engine.mirror(link, occurrence, user.id)

      assert_received {:payload, payload}

      # `Date` values, because every outbound mapper reads the type to decide
      # whether it is writing an all-day event.
      assert payload.all_day == true
      assert payload.start_time == ~D[2026-03-10]
      assert payload.end_time == ~D[2026-03-11]
      refute Map.has_key?(payload, :recurrence_rule)
    end

    test "a full_passthrough link carries the real title and still no rule", %{
      user: user,
      source: source,
      link: link
    } do
      {:ok, link} = CalendarSyncLinkQueries.update(link, %{privacy_tier: "full_passthrough"})
      {:ok, link} = CalendarSyncLinkQueries.get(link.id)

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        oauth_write_response("target-pid-1")
      end)

      assert :ok == Engine.mirror(link, caldav_series_occurrence(source), user.id)

      assert_received {:payload, payload}
      assert payload.summary == "Weekly standup"
      refute Map.has_key?(payload, :recurrence_rule)
    end
  end

  describe "the source-side capability says so too" do
    alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
    alias Tymeslot.Integrations.Calendar.ProviderConfig
    alias Tymeslot.Integrations.Calendar.SyncLink.Capability
    alias Tymeslot.Integrations.Calendar.SyncLink.RecurringSeries

    # `:series_lookup` is false for the family, and `api_module/1` agrees — the
    # equivalence stage 1 pins, asserted here for the CalDAV cells specifically
    # so that a later attempt to "finish" CalDAV by adding a lookup has to come
    # past this test and its reasoning.
    test "no CalDAV provider claims a series lookup, and none has an API module" do
      for provider <- ProviderConfig.caldav_based_provider_strings() do
        refute Capability.supports?(provider, :series_lookup),
               "#{provider} has no series master to fetch — its rows arrive expanded"

        assert RecurringSeries.api_module(%CalendarIntegrationSchema{provider: provider}) == nil
      end
    end
  end
end
