defmodule Tymeslot.Integrations.Calendar.SyncLink.EngineOutlookRecurrenceTest do
  @moduledoc """
  A recurring **Outlook** source becomes one recurring placeholder, or none.

  This is the same contract `EngineRecurrenceTest` pins for Google, and it is
  asserted the same way — on the payload handed to the provider, never on the
  stored mirror row. A row proves only that Tymeslot recorded a write; it says
  nothing about whether a rule reached the target, and a version that stored the
  row while sending no `recurrence_rule` would write a single block at the last
  occurrence's date and pass a row-only test.

  What makes Outlook its own path rather than a copy of Google's is the shape of
  the master. Graph does not speak RRULE: it carries a structured
  `recurrence` object of a `pattern` and a `range`, so the rule the placeholder
  needs has to be converted back through `RecurrenceConverter.outlook_to_rrule/1`
  rather than read off a list of iCalendar lines. The tests below assert the
  converted RRULE, because that conversion is the part that can silently produce
  `nil` and leave a series mirrored as one block.

  What makes it need a fetch *at all* is that every path Tymeslot syncs Outlook
  with is `calendarView` — `list_events/4`, `list_primary_events/3` and
  `/me/calendarView/delta` — and `calendarView` returns expanded occurrences,
  never the seriesMaster. So the cached row carries `seriesMasterId` and no
  rule, exactly as Google's carries `recurringEventId` and no rule.
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

  # An Outlook source onto a Google target. The target is Google because
  # `:recurrence` — the target-side capability — is Google's alone and remains
  # so: this stage earns Outlook the *source* side only. Pairing the two is what
  # makes the assertions here about the source path rather than about a refusal.
  setup do
    user = insert(:user)
    source = insert(:calendar_integration, user: user, provider: "outlook")
    target = insert(:calendar_integration, user: user, provider: "google")

    link =
      insert(:calendar_sync_link,
        user_id: user.id,
        source_integration_id: source.id,
        target_integration_id: target.id
      )

    # Reloaded through the query module so `source_integration` is preloaded, as
    # every production caller has it: the master fetch needs the source
    # integration's token, and the engine skips rather than raises without it.
    {:ok, link} = CalendarSyncLinkQueries.get(link.id)

    %{user: user, source: source, target: target, link: link}
  end

  defp expect_master(opts \\ [], times \\ 1) do
    expect(OutlookCalendarAPIMock, :get_event, times, fn _integration, _calendar_id, event_id ->
      assert event_id == "AAMkAGI2master="

      {:ok, outlook_series_master(opts)}
    end)
  end

  describe "a weekly Outlook source onto a Google target" do
    test "sends one placeholder carrying the master's rule, and records one mirror", %{
      user: user,
      source: source,
      link: link
    } do
      expect_master()

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        oauth_write_response("target-pid-1")
      end)

      instance = outlook_series_instance(source)
      assert :ok == Engine.mirror(link, instance, user.id)

      assert_received {:payload, payload}

      # Graph's `%{"pattern" => %{"type" => "weekly", "daysOfWeek" => ["tuesday"]}}`
      # converted back to the RRULE the target speaks. A version that forwarded
      # the Graph object, or that failed the conversion and sent `nil`, is what
      # this pins.
      assert payload.recurrence_rule == "FREQ=WEEKLY;BYDAY=TU"

      # Still a placeholder in every other respect.
      assert payload.summary == "Busy"
      assert payload.transparency == :opaque
      refute Map.has_key?(payload, :attendees)

      # ONE mirror row for the whole series.
      assert {:ok, mirror} =
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, instance.uid)

      assert mirror.target_uid == Engine.target_uid_for(link.id, instance.uid)
      assert [_only_one] = CalendarSyncMirrorQueries.list_for_link(link.id)
      assert mirror.target_provider_event_id == "target-pid-1"
    end

    test "the placeholder starts where the series starts, not where the cached row does", %{
      user: user,
      source: source,
      link: link
    } do
      expect_master()

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        oauth_write_response("target-pid-1")
      end)

      instance = outlook_series_instance(source)
      assert :ok == Engine.mirror(link, instance, user.id)

      assert_received {:payload, payload}

      # `calendarView` expands the series and the cache keeps the last
      # occurrence, so the row is December. Pairing that start with the master's
      # rule would describe "every Tuesday from December onwards, forever":
      # every real occurrence unblocked, every date after the series ends
      # blocked. The rule and the start must come from the same event.
      # Microseconds included: Graph writes `2026-03-03T09:00:00.0000000`, the
      # cache columns are `:utc_datetime_usec`, and the normaliser keeps the
      # fraction on the ordinary sync path too. Asserting the truncated form
      # would be asserting a shape the parse does not produce.
      assert payload.start_time == ~U[2026-03-03 09:00:00.000000Z]
      assert payload.end_time == ~U[2026-03-03 09:30:00.000000Z]

      refute payload.start_time == instance.start_at
    end

    test "an all-day series starts on the master's date", %{
      user: user,
      source: source,
      link: link
    } do
      expect(OutlookCalendarAPIMock, :get_event, fn _integration, _calendar_id, _event_id ->
        {:ok,
         Map.merge(outlook_series_master(), %{
           "isAllDay" => true,
           "start" => %{"dateTime" => "2026-03-03T00:00:00.0000000", "timeZone" => "UTC"},
           "end" => %{"dateTime" => "2026-03-04T00:00:00.0000000", "timeZone" => "UTC"}
         })}
      end)

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        oauth_write_response("target-pid-1")
      end)

      instance =
        outlook_series_instance(source, %{
          all_day: true,
          start_at: nil,
          end_at: nil,
          start_date: ~D[2026-12-15],
          end_date: ~D[2026-12-16]
        })

      assert :ok == Engine.mirror(link, instance, user.id)

      assert_received {:payload, payload}

      # The all-day branch has to follow the master too, and has to keep
      # emitting `Date` values: every outbound mapper reads the *type* to decide
      # whether it is writing an all-day event.
      assert payload.all_day == true
      assert payload.start_time == ~D[2026-03-03]
      assert payload.end_time == ~D[2026-03-04]
    end

    test "a full_passthrough link still carries the rule, and still no attendees", %{
      user: user,
      source: source,
      link: link
    } do
      {:ok, link} = CalendarSyncLinkQueries.update(link, %{privacy_tier: "full_passthrough"})
      {:ok, link} = CalendarSyncLinkQueries.get(link.id)

      expect_master()

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        oauth_write_response("target-pid-1")
      end)

      assert :ok == Engine.mirror(link, outlook_series_instance(source), user.id)

      assert_received {:payload, payload}
      assert payload.summary == "Weekly standup"
      assert payload.recurrence_rule == "FREQ=WEEKLY;BYDAY=TU"
      refute Map.has_key?(payload, :attendees)
    end

    test "a bounded series carries its UNTIL through the conversion", %{
      user: user,
      source: source,
      link: link
    } do
      # Graph expresses "until" as a `range` of type `endDate`; the RRULE the
      # target needs expresses it as an `UNTIL` part. The converter is what
      # bridges them, and a series whose end is lost blocks time forever.
      expect_master(
        recurrence: %{
          "pattern" => %{"type" => "weekly", "interval" => 1, "daysOfWeek" => ["tuesday"]},
          "range" => %{
            "type" => "endDate",
            "startDate" => "2026-03-03",
            "endDate" => "2026-12-15"
          }
        }
      )

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        oauth_write_response("target-pid-1")
      end)

      assert :ok == Engine.mirror(link, outlook_series_instance(source), user.id)

      assert_received {:payload, payload}
      assert payload.recurrence_rule =~ "FREQ=WEEKLY"
      assert payload.recurrence_rule =~ "UNTIL=20261215"
    end
  end

  describe "the master fetch costs one request per series per change" do
    test "one create writes one placeholder from one master fetch", %{
      user: user,
      source: source,
      link: link
    } do
      # `expect/4` with a count of 1 fails on a second call and
      # `verify_on_exit!` fails on none, so this pins exactly one fetch. A
      # per-occurrence version would call it once per expanded instance.
      expect_master([], 1)

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        oauth_write_response("target-pid-1")
      end)

      assert :ok == Engine.mirror(link, outlook_series_instance(source), user.id)
    end

    test "a non-recurring Outlook source costs no master fetch at all", %{
      user: user,
      source: source,
      link: link
    } do
      # No `expect` for `get_event` — a call would fail Mox verification.
      ordinary =
        outlook_series_instance(source, %{
          uid: "one-off@outlook",
          recurring_event_id: nil
        })

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        oauth_write_response("target-pid-1")
      end)

      assert :ok == Engine.mirror(link, ordinary, user.id)

      assert_received {:payload, payload}
      refute Map.has_key?(payload, :recurrence_rule)
    end
  end

  describe "a series the master cannot describe is skipped, never guessed" do
    test "a failed master fetch writes nothing and leaves the retry to the sweep", %{
      user: user,
      source: source,
      link: link
    } do
      expect(OutlookCalendarAPIMock, :get_event, fn _integration, _calendar_id, _event_id ->
        {:error, :rate_limited, "Rate limited"}
      end)

      instance = outlook_series_instance(source)

      assert {:discard, :series_master_unavailable} == Engine.mirror(link, instance, user.id)

      assert {:error, :not_found} ==
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, instance.uid)
    end

    test "a master whose recurrence Graph cannot express is skipped, not mirrored bare", %{
      user: user,
      source: source,
      link: link
    } do
      # `outlook_to_rrule/1` answers `nil` for a pattern outside the converter's
      # coverage — Graph's relative monthly/yearly forms. Mirroring such a master
      # with no rule would write a plain one-off block at the series' first
      # occurrence, which is the same wrong answer as trusting the cached row.
      expect_master(
        recurrence: %{
          "pattern" => %{"type" => "relativeMonthly", "interval" => 1, "index" => "first"},
          "range" => %{"type" => "noEnd", "startDate" => "2026-03-03"}
        }
      )

      instance = outlook_series_instance(source)

      assert {:discard, :series_master_unavailable} == Engine.mirror(link, instance, user.id)

      assert {:error, :not_found} ==
               CalendarSyncMirrorQueries.get_by_link_and_source_uid(link.id, instance.uid)
    end
  end
end
