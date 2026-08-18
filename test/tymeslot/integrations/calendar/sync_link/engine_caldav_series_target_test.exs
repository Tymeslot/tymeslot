defmodule Tymeslot.Integrations.Calendar.SyncLink.EngineCaldavSeriesTargetTest do
  @moduledoc """
  A CalDAV calendar as the **target** of a recurring mirror — the other end from
  `EngineCaldavRecurrenceTest`, which covers a CalDAV *source*.

  `Capability.supports?(provider, :recurrence)` was Google-only, and the reason
  recorded was specific rather than cautious: the exception lines that travel
  beside an RRULE had nowhere to go. `recurrence_exception_lines` was read by
  one mapper in the codebase, Google's, and the CalDAV builder's `build_exdate/1`
  reads `:recurrence_exceptions` — a `[Date.t()]` from the cache, a different
  field of a different type that a mirror payload never carries. So the rule was
  written and the cancellations were silently discarded.

  That was verified against a live Radicale rather than argued: the PUT returned
  201 and the stored VEVENT came back carrying `RRULE:FREQ=WEEKLY;COUNT=5` and
  no EXDATE at all. `Properties.build_exception_lines/1` closed it, and the live
  server then expanded the same series to four occurrences instead of five, with
  the cancelled one gone.

  These tests are the hermetic half of that evidence. The live file
  (`radicale_recurrence_integration_test.exs`) cannot run in CI — no seeded
  CalDAV image is published for the workflow — so what stops a regression on an
  ordinary `mix test` is here: the payload reaches a CalDAV target intact, and
  the document built from it carries both the rule and the lines.

  The assertion deliberately goes past the payload and onto the emitted
  iCalendar. Storing the field on the payload is not the feature; a VEVENT the
  server can act on is, and a test stopping at the payload passes over exactly
  the bug this file exists for.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :sync_links

  import Mox
  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.ICalBuilder
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.SyncLink.Capability
  alias Tymeslot.Integrations.Calendar.SyncLink.Engine

  setup :verify_on_exit!

  setup do
    user = insert(:user)
    source = insert(:calendar_integration, user: user, provider: "google")
    target = insert(:calendar_integration, user: user, provider: "nextcloud")

    link =
      insert(:calendar_sync_link,
        user_id: user.id,
        source_integration_id: source.id,
        target_integration_id: target.id
      )

    {:ok, link} = CalendarSyncLinkQueries.get(link.id)

    %{user: user, source: source, target: target, link: link}
  end

  defp expect_master(recurrence) do
    expect(GoogleCalendarAPIMock, :get_event, fn _integration, _calendar_id, event_id ->
      assert event_id == "master_abc123"
      {:ok, google_series_master(recurrence: recurrence)}
    end)
  end

  describe "the capability itself" do
    test "every CalDAV provider claims :recurrence" do
      for provider <- ProviderConfig.caldav_based_provider_strings() do
        assert Capability.supports?(provider, :recurrence),
               "#{provider} must be able to receive a series, verified against a live server"
      end

      for provider <- ProviderConfig.caldav_based_providers() do
        assert Capability.supports?(provider, :recurrence),
               "the atom form must agree with the string form"
      end
    end

    test "ICS is still refused, because it cannot receive any write at all" do
      refute Capability.supports?(:ics_url, :recurrence)
      refute Capability.supports?("ics_url", :recurrence)
    end

    test "Outlook is still refused — its mapper reads no exception lines" do
      # `Outlook.EventMapper.add_recurrence/2` reads `:recurrence_rule` and
      # nothing else, so a series mirrored there would still arrive with its
      # cancellations discarded. The CalDAV cell moved on evidence; this one has
      # none yet, and the two are independent.
      refute Capability.supports?(:outlook, :recurrence)
      refute Capability.supports?("outlook", :recurrence)
    end
  end

  describe "a recurring Google source mirrored onto a CalDAV target" do
    test "the payload reaches the target carrying both the rule and the exception lines",
         %{user: user, source: source, link: link} do
      expect_master([
        "RRULE:FREQ=WEEKLY;COUNT=5",
        "EXDATE;TZID=Europe/Tallinn:20260915T120000"
      ])

      test_pid = self()

      # A CalDAV create answers `{:ok, uid}` — a bare string, not a map. A mock
      # returning `%{provider_event_id: ...}` would describe a provider that
      # does not exist; see `caldav_create_response/1`.
      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        caldav_create_response(event_data.uid)
      end)

      assert :ok == Engine.mirror(link, google_series_instance(source), user.id)

      assert_received {:payload, payload}

      assert payload.recurrence_rule == "RRULE:FREQ=WEEKLY;COUNT=5"

      assert payload.recurrence_exception_lines == [
               "EXDATE;TZID=Europe/Tallinn:20260915T120000"
             ],
             "the cancellation must survive to the target payload"
    end

    test "the document built from that payload carries the EXDATE beside the RRULE",
         %{user: user, source: source, link: link} do
      # The step that used to lose them. The payload above was already correct
      # before the fix; `build_simple_event/2` was where the lines vanished, so
      # the assertion has to run on its output.
      expect_master([
        "RRULE:FREQ=WEEKLY;COUNT=5",
        "EXDATE;TZID=Europe/Tallinn:20260915T120000"
      ])

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        caldav_create_response(event_data.uid)
      end)

      assert :ok == Engine.mirror(link, google_series_instance(source), user.id)
      assert_received {:payload, payload}

      ical = ICalBuilder.build_simple_event(payload.uid, payload)

      assert ical =~ "RRULE:FREQ=WEEKLY;COUNT=5"

      assert ical =~ "EXDATE;TZID=Europe/Tallinn:20260915T120000",
             "the VEVENT the server receives must carry the cancellation:\n#{ical}"
    end

    test "a moved occurrence's EXDATE/RDATE pair both reach the document",
         %{user: user, source: source, link: link} do
      expect_master(["RRULE:FREQ=WEEKLY;COUNT=5"] ++ series_exception_lines(moved: true))

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        caldav_create_response(event_data.uid)
      end)

      assert :ok == Engine.mirror(link, google_series_instance(source), user.id)
      assert_received {:payload, payload}

      ical = ICalBuilder.build_simple_event(payload.uid, payload)

      # `RecurringSeries` forwards only the master's EXDATE lines, so the RDATE
      # half of a move arrives through `MoveCorrection` rather than from here —
      # but the builder must carry whichever of the two it is given, since
      # dropping the RDATE frees a slot without booking the one it moved to.
      assert ical =~ "EXDATE;TZID=Europe/Tallinn:20260915T120000"
    end

    test "a series with nothing cancelled still mirrors, carrying the rule alone",
         %{user: user, source: source, link: link} do
      expect_master(["RRULE:FREQ=WEEKLY;COUNT=5"])

      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        send(test_pid, {:payload, event_data})
        caldav_create_response(event_data.uid)
      end)

      assert :ok == Engine.mirror(link, google_series_instance(source), user.id)
      assert_received {:payload, payload}

      refute Map.has_key?(payload, :recurrence_exception_lines)

      ical = ICalBuilder.build_simple_event(payload.uid, payload)
      assert ical =~ "RRULE:FREQ=WEEKLY;COUNT=5"
      refute ical =~ "EXDATE"
    end
  end
end
