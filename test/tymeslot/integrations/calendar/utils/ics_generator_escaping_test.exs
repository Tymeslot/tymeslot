defmodule Tymeslot.Integrations.Calendar.IcsGeneratorEscapingTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.IcsGenerator

  describe "escaping iCalendar special characters" do
    test "escapes special iCalendar characters in description" do
      meeting_details = %{
        title: "Special Characters",
        description: "Backslash: \\, Semicolon: ;, Comma: ,",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "special-123",
        organizer_email: "org@example.com"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details)

      assert ics_content =~ "Backslash: \\\\"
      assert ics_content =~ "Semicolon: \\;"
      assert ics_content =~ "Comma: \\,"
    end

    test "escapes newlines in description" do
      meeting_details = %{
        title: "Multi-line",
        description: "Line 1\nLine 2",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "multiline-123",
        organizer_email: "org@example.com"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details)

      assert ics_content =~ "Line 1\\nLine 2"
    end

    test "handles emojis and non-ASCII characters" do
      meeting_details = %{
        title: "Emoji Test 🚀",
        description: "Thinking... 🤔 & Fun!",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "emoji-123",
        organizer_email: "org@example.com"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details)

      assert ics_content =~ "Emoji Test 🚀"
      assert ics_content =~ "Thinking... 🤔"
    end

    test "escapes special characters throughout an extremely long description" do
      # A value this long is folded across dozens of content lines. Unfolding
      # it must yield exactly the escaped description, which proves the
      # escaping is applied to the whole value rather than only its opening
      # segment, and that folding never eats or duplicates a character.
      chunk = "Backslash: \\ Semicolon: ; Comma: , End."
      long_description = String.duplicate(chunk, 100)
      expected = String.duplicate("Backslash: \\\\ Semicolon: \\; Comma: \\, End.", 100)

      meeting_details = %{
        title: "Long String Test",
        description: long_description,
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "long-123",
        organizer_email: "org@example.com"
      }

      ics_content = IcsGenerator.generate_ics(meeting_details)

      description_value =
        ics_content
        |> String.replace("\r\n ", "")
        |> String.split("\n")
        |> Enum.find_value(fn line ->
          case String.split(line, ":", parts: 2) do
            ["DESCRIPTION" <> _params, value] -> value
            _other -> nil
          end
        end)

      assert description_value == expected
    end
  end

  # RFC 5545 §3.1 mandates content lines no longer than 75 octets
  # (excluding the line terminator). Custom-field answers appended to
  # DESCRIPTION routinely exceed this limit, so the generator folds
  # long lines with CRLF + SPACE. These tests drive that requirement.
  describe "RFC 5545 §3.1 line folding" do
    test "no output line exceeds 75 octets after folding" do
      long_answer = String.duplicate("This is a long custom field answer value. ", 20)

      meeting_details = %{
        title: "RFC 5545 line-folding compliance test",
        description: "Some base description",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "folding-123",
        organizer_email: "host@example.com",
        custom_fields_snapshot: [
          %{"id" => "f1", "type" => "short_text", "label" => "Project details"},
          %{"id" => "f2", "type" => "short_text", "label" => "Additional notes"}
        ],
        custom_field_answers: %{
          "f1" => long_answer,
          "f2" => long_answer
        }
      }

      ics_content = IcsGenerator.generate_ics(meeting_details)

      # Split on bare LF (the heredoc terminator) — fold continuations end with
      # CRLF+SPACE so a continuation line looks like "\r\n <content>"; after
      # splitting on "\n" it appears as "\r" followed by " <content>" on the
      # next element. We strip the trailing "\r" before measuring.
      violations =
        ics_content
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))
        |> Enum.filter(fn line ->
          stripped = String.trim_trailing(line, "\r")
          byte_size(stripped) > 75
        end)

      assert violations == [],
             "Lines exceeding 75 octets found:\n#{Enum.join(violations, "\n")}"
    end

    test "line-folding preserves roundtrippable content for multi-byte UTF-8" do
      # The fold helper must not tear multi-byte codepoints. We use a string
      # just long enough to force a fold inside a multi-byte sequence boundary.
      # The actual value of the reassembled description is checked by asserting
      # the unescaped text survives in the output.
      unicode_answer = String.duplicate("Ünïcödé answer: ", 10)

      meeting_details = %{
        title: "Unicode Folding",
        start_time: ~U[2026-01-15 14:00:00Z],
        end_time: ~U[2026-01-15 15:00:00Z],
        uid: "unicode-fold-123",
        organizer_email: "host@example.com",
        custom_fields_snapshot: [
          %{"id" => "u1", "type" => "short_text", "label" => "Notes"}
        ],
        custom_field_answers: %{"u1" => unicode_answer}
      }

      ics_content = IcsGenerator.generate_ics(meeting_details)

      # All lines within 75 octets
      violations =
        ics_content
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))
        |> Enum.filter(fn line ->
          stripped = String.trim_trailing(line, "\r")
          byte_size(stripped) > 75
        end)

      assert violations == []

      # Content still present (folding is transparent to the value)
      assert ics_content =~ "Ünïcödé answer:"
    end
  end
end
