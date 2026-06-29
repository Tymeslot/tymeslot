defmodule Tymeslot.Integrations.Calendar.ICalBuilder.FormatTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.ICalBuilder.Format

  describe "generate_uid/0" do
    test "generates unique identifier" do
      uid1 = Format.generate_uid()
      uid2 = Format.generate_uid()

      assert uid1 != uid2
      assert String.contains?(uid1, "@tymeslot.com")
      assert String.contains?(uid2, "@tymeslot.com")
    end

    test "generates UID in correct format" do
      uid = Format.generate_uid()

      assert String.ends_with?(uid, "@tymeslot.com")
      assert String.length(uid) > 20
    end
  end

  describe "format_datetime/1" do
    test "formats DateTime in iCalendar format" do
      datetime = ~U[2024-01-15 10:30:45.123456Z]

      formatted = Format.format_datetime(datetime)

      assert formatted == "20240115T103045Z"
    end

    test "removes fractional seconds" do
      datetime = ~U[2024-12-31 23:59:59.999999Z]

      formatted = Format.format_datetime(datetime)

      assert formatted == "20241231T235959Z"
      refute String.contains?(formatted, ".")
    end

    test "formats midnight correctly" do
      datetime = ~U[2024-06-15 00:00:00Z]

      formatted = Format.format_datetime(datetime)

      assert formatted == "20240615T000000Z"
    end
  end

  describe "format_date/1" do
    test "formats Date in iCalendar format" do
      date = ~D[2024-01-15]

      formatted = Format.format_date(date)

      assert formatted == "20240115"
    end

    test "formats various dates correctly" do
      assert Format.format_date(~D[2024-12-31]) == "20241231"
      assert Format.format_date(~D[2024-01-01]) == "20240101"
      assert Format.format_date(~D[2024-06-15]) == "20240615"
    end
  end

  describe "escape_text/1" do
    test "returns empty string for nil" do
      assert Format.escape_text(nil) == ""
    end

    test "escapes backslashes" do
      assert Format.escape_text("C:\\path\\to\\file") == "C:\\\\path\\\\to\\\\file"
    end

    test "escapes commas" do
      assert Format.escape_text("one, two, three") == "one\\, two\\, three"
    end

    test "escapes semicolons" do
      assert Format.escape_text("key;value;pair") == "key\\;value\\;pair"
    end

    test "escapes newlines" do
      assert Format.escape_text("line1\nline2") == "line1\\nline2"
    end

    test "removes carriage returns" do
      assert Format.escape_text("text\r\nmore") == "text\\nmore"
    end

    test "handles multiple special characters" do
      text = "Path: C:\\test; value,\nNext line"
      escaped = Format.escape_text(text)

      assert String.contains?(escaped, "\\\\")
      assert String.contains?(escaped, "\\;")
      assert String.contains?(escaped, "\\,")
      assert String.contains?(escaped, "\\n")
    end

    test "preserves regular text" do
      assert Format.escape_text("Regular text 123") == "Regular text 123"
    end
  end
end
