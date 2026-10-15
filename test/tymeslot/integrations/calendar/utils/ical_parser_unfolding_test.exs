defmodule Tymeslot.Integrations.Calendar.ICalParserUnfoldingTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.ICalParser

  # RFC 5545 §3.1: unfolding removes the line break and exactly one
  # whitespace character. Any further whitespace is part of the value.

  defp summary_of(summary_lines, eol) do
    ical =
      Enum.join(
        [
          "BEGIN:VCALENDAR",
          "VERSION:2.0",
          "BEGIN:VEVENT",
          "UID:unfold@example.com",
          "DTSTART:20240315T100000Z",
          "DTEND:20240315T110000Z",
          summary_lines,
          "END:VEVENT",
          "END:VCALENDAR",
          ""
        ],
        eol
      )

    assert {:ok, [event]} = ICalParser.parse(ical)
    event.summary
  end

  for {name, eol} <- [crlf: "\r\n", lf: "\n"] do
    @eol eol

    test "single-space fold rejoins a split word (#{name})" do
      assert summary_of("SUMMARY:Quarterly plan" <> @eol <> "  ning", @eol) ==
               "Quarterly plan ning"

      assert summary_of("SUMMARY:Quarterly plan" <> @eol <> " ning", @eol) ==
               "Quarterly planning"
    end

    test "a real space after the fold space is kept (#{name})" do
      assert summary_of("SUMMARY:so" <> @eol <> "  that", @eol) == "so that"
    end

    test "tab fold removes only the tab (#{name})" do
      assert summary_of("SUMMARY:so" <> @eol <> "\tthat", @eol) == "sothat"
      assert summary_of("SUMMARY:so" <> @eol <> "\t that", @eol) == "so that"
    end

    test "several continuation lines join in order (#{name})" do
      assert summary_of("SUMMARY:one" <> @eol <> " two" <> @eol <> "  three", @eol) ==
               "onetwo three"
    end
  end

  test "multi-byte UTF-8 split across a fold is reassembled" do
    <<head::binary-size(1), tail::binary>> = "é"

    assert summary_of("SUMMARY:caf" <> head <> "\r\n " <> tail <> " au lait", "\r\n") ==
             "café au lait"
  end
end
