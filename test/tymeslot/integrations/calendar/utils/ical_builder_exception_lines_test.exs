defmodule Tymeslot.Integrations.Calendar.ICalBuilderExceptionLinesTest do
  @moduledoc """
  A mirror payload's `recurrence_exception_lines` must reach the VEVENT.

  This file exists because the CalDAV write path used to emit the RRULE and
  drop the exception lines beside it, and the drop was silent at every layer:
  `build_simple_event/2` filtered `nil` out of its line list, so a series whose
  occurrences had been cancelled was PUT as an unbroken series and the server
  answered 201. Verified against a live Radicale before the fix — the stored
  VEVENT carried `RRULE:FREQ=WEEKLY;COUNT=5` and no EXDATE at all.

  The failure that produces is not an error anyone sees. A cancelled occurrence
  keeps blocking its slot on the target calendar for as long as the rule runs,
  and nothing retries it, because from the writer's point of view the write
  succeeded.

  The assertions here are on the emitted document rather than on the payload,
  for the reason `per_calendar_appearance_test.exs` states: building the payload
  is not the feature, and a test that stops there passes over exactly this bug.
  """
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.ICalBuilder

  # The shape `MirrorPayload.build/4` actually produces for a recurring source,
  # captured from a live run rather than invented: `:recurrence_exception_lines`
  # holds whole RFC 5545 property lines, already prefixed and already carrying
  # their own TZID parameter, because `RecurringSeries` keeps the master's lines
  # verbatim and `MoveCorrection.lines_for/2` writes them in the same form.
  defp mirror_payload(lines) do
    %{
      uid: "probe-series-1",
      summary: "Busy",
      status: :confirmed,
      transparency: :opaque,
      all_day: false,
      start_time: ~U[2026-09-01 09:00:00Z],
      end_time: ~U[2026-09-01 09:30:00Z],
      timezone: "Europe/Tallinn",
      recurrence_rule: "FREQ=WEEKLY;COUNT=5",
      recurrence_exception_lines: lines
    }
  end

  describe "build_simple_event/2 with a mirror payload's exception lines" do
    test "emits the EXDATE line verbatim beside the RRULE" do
      ical =
        ICalBuilder.build_simple_event(
          "probe-series-1",
          mirror_payload(["EXDATE;TZID=Europe/Tallinn:20260915T090000"])
        )

      assert ical =~ "RRULE:FREQ=WEEKLY;COUNT=5"

      assert ical =~ "EXDATE;TZID=Europe/Tallinn:20260915T090000",
             "the cancelled occurrence's EXDATE must survive to the document"
    end

    test "emits an EXDATE/RDATE pair, which is what a moved occurrence needs" do
      # `MoveCorrection.lines_for/2` always writes both halves: the EXDATE frees
      # the slot the occurrence left and the RDATE books the one it moved to.
      # Emitting only the EXDATE widens the double-booking window rather than
      # closing it.
      ical =
        ICalBuilder.build_simple_event(
          "probe-series-1",
          mirror_payload([
            "EXDATE;TZID=Europe/Tallinn:20260915T090000",
            "RDATE;TZID=Europe/Tallinn:20260916T090000"
          ])
        )

      assert ical =~ "EXDATE;TZID=Europe/Tallinn:20260915T090000"
      assert ical =~ "RDATE;TZID=Europe/Tallinn:20260916T090000"
    end

    test "keeps each line's own parameters rather than re-deriving them" do
      # The instant a cancellation happened lives in the TZID parameter, which
      # sits between the property name and the colon. Anything that strips and
      # re-adds a prefix either no-ops or discards the timezone, and a discarded
      # timezone cancels the wrong occurrence.
      ical =
        ICalBuilder.build_simple_event(
          "probe-series-1",
          mirror_payload(["EXDATE;VALUE=DATE:20260915,20260922"])
        )

      assert ical =~ "EXDATE;VALUE=DATE:20260915,20260922"
      refute ical =~ "EXDATE:EXDATE"
    end

    test "emits no exception property when the payload carries none" do
      ical =
        ICalBuilder.build_simple_event("probe-series-1", %{
          uid: "probe-series-1",
          summary: "Busy",
          all_day: false,
          start_time: ~U[2026-09-01 09:00:00Z],
          end_time: ~U[2026-09-01 09:30:00Z],
          recurrence_rule: "FREQ=WEEKLY;COUNT=5"
        })

      assert ical =~ "RRULE:FREQ=WEEKLY;COUNT=5"
      refute ical =~ "EXDATE"
      refute ical =~ "RDATE"
    end

    test "drops exception lines that name no rule to except against" do
      # An EXDATE with no RRULE beside it describes exclusions from a series
      # that is not there. Google's mapper drops them for the same reason.
      ical =
        ICalBuilder.build_simple_event("probe-series-1", %{
          uid: "probe-series-1",
          summary: "Busy",
          all_day: false,
          start_time: ~U[2026-09-01 09:00:00Z],
          end_time: ~U[2026-09-01 09:30:00Z],
          recurrence_exception_lines: ["EXDATE;TZID=Europe/Tallinn:20260915T090000"]
        })

      refute ical =~ "EXDATE"
    end

    test "ignores blank and non-string entries rather than emitting empty lines" do
      ical =
        ICalBuilder.build_simple_event(
          "probe-series-1",
          mirror_payload(["EXDATE;TZID=Europe/Tallinn:20260915T090000", "", nil])
        )

      assert ical =~ "EXDATE;TZID=Europe/Tallinn:20260915T090000"

      refute ical =~ "\r\n\r\n",
             "a blank entry must not become a blank content line"
    end

    test "the date-typed `recurrence_exceptions` field still works alongside" do
      # The two fields are different shapes with different names on purpose —
      # `recurrence_exceptions` is `[Date.t()]` from the cache, the lines are
      # `[String.t()]` from a mirror payload. A payload carrying both is not a
      # shape production builds, but neither field may silence the other.
      ical =
        ICalBuilder.build_simple_event("probe-series-1", %{
          uid: "probe-series-1",
          summary: "Busy",
          all_day: false,
          start_time: ~U[2026-09-01 09:00:00Z],
          end_time: ~U[2026-09-01 09:30:00Z],
          recurrence_rule: "FREQ=WEEKLY;COUNT=5",
          recurrence_exceptions: [~D[2026-09-08]]
        })

      assert ical =~ "EXDATE:20260908T090000Z"
    end
  end
end
