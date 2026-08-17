defmodule Tymeslot.Integrations.Calendar.SyncLink.MoveCorrectionTest do
  @moduledoc """
  The two iCalendar lines that put a moved occurrence's block where the meeting
  actually is.

  A mirrored series is one recurring placeholder built from the master's rule.
  Moving one occurrence does not touch that rule, so the placeholder goes on
  expanding the occurrence at the time it left — and nothing covers the time it
  went to. Both halves are wrong, and the second is the damaging one: a slot
  that is genuinely busy stays bookable by anything reading the target.

  The correction is a pair. `EXDATE` at the original instant frees the slot the
  occurrence left; `RDATE` at the new one blocks the slot it went to. Either
  alone makes things worse in one direction — EXDATE by itself widens the
  double-booking window, which is why a previous pass rejected it — so the
  tests assert them together and assert what each contributes.

  The parameters carry the meaning. A timed occurrence needs `TZID` so the
  instant is the one the organiser sees rather than a UTC reading of it, and an
  all-day one needs `VALUE=DATE`, because a date is not a time and a provider
  handed a date-time for an all-day series writes the wrong kind of block.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :sync_links

  alias Tymeslot.Integrations.Calendar.SyncLink.MoveCorrection

  describe "lines_for/2 — a timed occurrence" do
    test "frees the original instant and blocks the new one" do
      moves = [
        %{original_start: ~U[2026-08-14 14:00:00Z], new_start: ~U[2026-08-14 22:00:00Z]}
      ]

      assert MoveCorrection.lines_for(moves, "Europe/Tallinn") == [
               "EXDATE;TZID=Europe/Tallinn:20260814T170000",
               "RDATE;TZID=Europe/Tallinn:20260815T010000"
             ]
    end

    test "renders each instant in the series' own zone, not UTC" do
      # 14:00Z is 17:00 in Tallinn (+03 in August). Emitting the UTC wall clock
      # under a TZID label would name 14:00 local — three hours from the
      # occurrence, and a block in the wrong place is the failure this exists to
      # remove.
      moves = [
        %{original_start: ~U[2026-08-14 14:00:00Z], new_start: ~U[2026-08-14 15:00:00Z]}
      ]

      [exdate, rdate] = MoveCorrection.lines_for(moves, "Europe/Tallinn")

      assert exdate =~ "T170000"
      assert rdate =~ "T180000"
    end

    test "several moves in one series produce a line per move, in order" do
      moves = [
        %{original_start: ~U[2026-08-03 13:00:00Z], new_start: ~U[2026-08-03 12:30:00Z]},
        %{original_start: ~U[2026-08-12 18:00:00Z], new_start: ~U[2026-08-13 19:00:00Z]}
      ]

      lines = MoveCorrection.lines_for(moves, "Etc/UTC")

      assert length(lines) == 4
      assert Enum.count(lines, &String.starts_with?(&1, "EXDATE")) == 2
      assert Enum.count(lines, &String.starts_with?(&1, "RDATE")) == 2
    end
  end

  # The shape that actually reaches the write. Moves are detected as atom-keyed
  # structs carrying DateTimes, then travel to the worker on an Oban job, where
  # JSONB round-trips them to string keys and ISO 8601 strings. A version reading
  # only the detected shape passes every test that calls this directly and emits
  # nothing for every job that carries one.
  describe "lines_for/2 — moves as the job carries them" do
    test "string keys and ISO 8601 strings produce the same lines as the structs" do
      as_detected = [
        %{original_start: ~U[2026-08-14 14:00:00Z], new_start: ~U[2026-08-14 22:00:00Z]}
      ]

      as_carried = [
        %{"original_start" => "2026-08-14T14:00:00Z", "new_start" => "2026-08-14T22:00:00Z"}
      ]

      assert MoveCorrection.lines_for(as_carried, "Europe/Tallinn") ==
               MoveCorrection.lines_for(as_detected, "Europe/Tallinn")

      assert MoveCorrection.lines_for(as_carried, "Europe/Tallinn") == [
               "EXDATE;TZID=Europe/Tallinn:20260814T170000",
               "RDATE;TZID=Europe/Tallinn:20260815T010000"
             ]
    end

    test "an all-day move survives the round trip as dates" do
      as_carried = [%{"original_start" => "2026-08-14", "new_start" => "2026-08-17"}]

      assert MoveCorrection.lines_for(as_carried, "Europe/Tallinn") == [
               "EXDATE;VALUE=DATE:20260814",
               "RDATE;VALUE=DATE:20260817"
             ]
    end

    test "an unparseable value is skipped rather than guessed at" do
      assert MoveCorrection.lines_for(
               [%{"original_start" => "not-a-date", "new_start" => "2026-08-17"}],
               "Etc/UTC"
             ) == []
    end
  end

  describe "lines_for/2 — an all-day occurrence" do
    test "uses VALUE=DATE and carries no zone" do
      # A date has no instant to place in a zone. Emitting `TZID` here, or a
      # date-time, makes the target write a timed block for an all-day meeting.
      moves = [%{original_start: ~D[2026-08-14], new_start: ~D[2026-08-17]}]

      assert MoveCorrection.lines_for(moves, "Europe/Tallinn") == [
               "EXDATE;VALUE=DATE:20260814",
               "RDATE;VALUE=DATE:20260817"
             ]
    end
  end

  describe "apply_to/3 — where the corrections join the series options" do
    @moves [%{original_start: ~U[2026-08-14 14:00:00Z], new_start: ~U[2026-08-14 22:00:00Z]}]

    test "appends to the master's own exception lines rather than replacing them" do
      opts = [
        recurrence_rule: "RRULE:FREQ=WEEKLY;BYDAY=TU",
        exceptions: ["EXDATE;TZID=Europe/Tallinn:20260901T120000"]
      ]

      result = MoveCorrection.apply_to(opts, %{timezone: "Europe/Tallinn"}, @moves)

      assert result[:exceptions] == [
               "EXDATE;TZID=Europe/Tallinn:20260901T120000",
               "EXDATE;TZID=Europe/Tallinn:20260814T170000",
               "RDATE;TZID=Europe/Tallinn:20260815T010000"
             ]
    end

    test "a series carrying no exceptions gets the pair on its own" do
      opts = [recurrence_rule: "RRULE:FREQ=WEEKLY;BYDAY=TU"]

      result = MoveCorrection.apply_to(opts, %{timezone: "Etc/UTC"}, @moves)

      assert result[:exceptions] == [
               "EXDATE;TZID=Etc/UTC:20260814T140000",
               "RDATE;TZID=Etc/UTC:20260814T220000"
             ]
    end

    # The guard that keeps a one-off event from being handed a recurrence it
    # does not have. `RecurringSeries.resolve/2` answers `{:ok, []}` for a
    # non-recurring source, so options with no rule reach here in ordinary use —
    # and an EXDATE with no RRULE to except against is exactly the malformed
    # payload `RecurringSeries` refuses forwarded lines to avoid.
    test "options carrying no recurrence rule are returned untouched" do
      assert MoveCorrection.apply_to([], %{timezone: "Etc/UTC"}, @moves) == []

      assert MoveCorrection.apply_to([timing: %{}], %{timezone: "Etc/UTC"}, @moves) == [
               timing: %{}
             ]
    end

    test "no moves leaves the options exactly as they were" do
      opts = [recurrence_rule: "RRULE:FREQ=WEEKLY", exceptions: ["EXDATE;VALUE=DATE:20260901"]]

      assert MoveCorrection.apply_to(opts, %{timezone: "Etc/UTC"}, []) == opts
    end
  end

  describe "lines_for/2 — what it refuses to guess" do
    test "no moves produce no lines" do
      assert MoveCorrection.lines_for([], "Europe/Tallinn") == []
    end

    test "a move whose two halves disagree in kind is skipped" do
      # A date original against a date-time new start cannot be rendered as a
      # matching pair, and half a correction is worse than none: an EXDATE with
      # no RDATE is the combination a previous pass rejected for widening the
      # double-booking window.
      moves = [%{original_start: ~D[2026-08-14], new_start: ~U[2026-08-17 09:00:00Z]}]

      assert MoveCorrection.lines_for(moves, "Europe/Tallinn") == []
    end

    test "a nil zone falls back to UTC rather than emitting a bare instant" do
      moves = [
        %{original_start: ~U[2026-08-14 14:00:00Z], new_start: ~U[2026-08-14 15:00:00Z]}
      ]

      assert MoveCorrection.lines_for(moves, nil) == [
               "EXDATE;TZID=Etc/UTC:20260814T140000",
               "RDATE;TZID=Etc/UTC:20260814T150000"
             ]
    end
  end
end
