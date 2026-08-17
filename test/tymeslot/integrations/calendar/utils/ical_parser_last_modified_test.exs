defmodule Tymeslot.Integrations.Calendar.ICalParserLastModifiedTest do
  @moduledoc """
  LAST-MODIFIED (RFC 5545 §3.8.7.3) — the server's own record of when it last
  changed a VEVENT, and the only staleness input a CalDAV collection offers in
  place of Google's `updated`.

  It reaches `provider_updated_at` through `ICalNormaliser`, and every consumer
  of that field — the reconcile sweep's staleness check, `ConflictLog`'s
  timestamp comparison, the baseline `Engine` stamps on a mapping — reads a
  missing value as "cannot tell" and stands down. So a parser that quietly drops
  the property does not fail: it disarms all of them, and looks exactly like a
  calendar nobody edits.
  """
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.ICalParser

  defp vevent(lines) do
    """
    BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    UID:modified-123@example.com
    DTSTART:20300115T100000Z
    DTEND:20300115T110000Z
    SUMMARY:Team Meeting
    #{lines}
    END:VEVENT
    END:VCALENDAR
    """
  end

  describe "parse/1 LAST-MODIFIED" do
    test "extracts it as a UTC datetime" do
      assert {:ok, [event]} = ICalParser.parse(vevent("LAST-MODIFIED:20260817T143211Z"))
      assert event.last_modified == ~U[2026-08-17 14:32:11Z]
    end

    test "leaves it nil when the VEVENT omits the property" do
      assert {:ok, [event]} = ICalParser.parse(vevent(""))
      assert event.last_modified == nil
    end

    # The property is bookkeeping; the event is the thing. A publisher writing a
    # value the parser cannot resolve costs a baseline, never the VEVENT around
    # it — the same trade the DTSTART/DTEND parses already make.
    test "leaves an unparseable value nil without dropping the event" do
      assert {:ok, [event]} = ICalParser.parse(vevent("LAST-MODIFIED:not-a-timestamp"))
      assert event.last_modified == nil
      assert event.uid == "modified-123@example.com"
      assert %DateTime{} = event.start_time
    end

    # A bare `YYYYMMDD` is a DATE, not an instant. `parse_datetime_property/2`
    # falls back to a `Date` for it — correct for an all-day DTSTART, but
    # `provider_updated_at` is `:utc_datetime_usec` and a Date would be rejected
    # at the boundary, so `ICalNormaliser` must not forward one.
    test "does not yield a bare date as a modification instant" do
      assert {:ok, [event]} = ICalParser.parse(vevent("LAST-MODIFIED:20260817"))
      refute match?(%DateTime{}, event.last_modified)
    end
  end
end
